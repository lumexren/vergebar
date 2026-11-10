// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of vergebar.
//
// Copyright (c) 2026 lumexren
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://gnu.org/licenses>.

const CustomModule = @This();

pub const SignalModuleNode = @import("SignalModuleNode.zig");

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;
const atomic = std.atomic;
const json = std.json;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const sh = @import("utils").sh;
const env = @import("utils").env;

base: *BaseModule,
exec_cmd: [:0]const u8,
exec_if_cmd: ?[:0]const u8 = null,
hide_empty_text: bool = false,
return_type_json: bool,
interval_sec: u32,
restart_interval_sec: u32,
signal_num: ?i32 = null,
timer_id: u32 = 0,
stream_thread: ?Thread = null,
running: atomic.Value(bool) = .init(true),

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*CustomModule {
    const this = try allocator.create(CustomModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, name, settings);
    errdefer base_mod.deinit();

    const raw_exec = settings.getString("exec") orelse "";
    const expanded_exec = try expandTilde(allocator, raw_exec);
    defer allocator.free(expanded_exec);

    const exec_if_str = settings.getString("exec-if");
    const expanded_exec_if = if (exec_if_str) |ei| try expandTilde(allocator, ei) else null;
    defer if (expanded_exec_if) |ei| allocator.free(ei);

    this.exec_cmd = try allocator.dupeSentinel(u8, expanded_exec, 0);
    this.exec_if_cmd = if (expanded_exec_if) |ei| try allocator.dupeSentinel(u8, ei, 0) else null;
    this.hide_empty_text = settings.getBool("hide-empty-text") orelse false;

    const rt = settings.getString("return-type") orelse "";
    this.return_type_json = mem.eql(u8, rt, "json");
    this.interval_sec = @intCast(settings.getInt("interval") orelse 0);
    this.restart_interval_sec = @intCast(settings.getInt("restart-interval") orelse 5);

    const sig_val = settings.getInt("signal");
    this.signal_num = if (sig_val) |s| @intCast(s) else null;

    this.* = .{
        .base = base_mod,
        .exec_cmd = this.exec_cmd,
        .exec_if_cmd = this.exec_if_cmd,
        .hide_empty_text = this.hide_empty_text,
        .return_type_json = this.return_type_json,
        .interval_sec = this.interval_sec,
        .restart_interval_sec = this.restart_interval_sec,
        .signal_num = this.signal_num,
    };

    if (this.signal_num) |sig| registerSignalModule(sig, this);

    if (this.interval_sec > 0 or this.signal_num != null) {
        this.runOnce();
        if (this.interval_sec > 0) this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);
    } else {
        this.stream_thread = Thread.spawn(.{}, streamWorker, .{this}) catch null;
    }

    return this;
}

pub fn deinit(this: *CustomModule) void {
    const alloc = this.base.allocator;
    this.running.store(false, .seq_cst);
    if (this.signal_num) |sig| unregisterSignalModule(sig, this);
    if (this.timer_id != 0) _ = gtk.g_source_remove(this.timer_id);
    if (this.stream_thread) |thread| thread.detach();
    alloc.free(this.exec_cmd);
    if (this.exec_if_cmd) |ei| alloc.free(ei);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn runOnce(this: *CustomModule) void {
    if (this.exec_cmd.len == 0) return;

    if (this.exec_if_cmd) |if_cmd| {
        var dummy_buf: [1]u8 = undefined;
        const res_len = sh.runBuf(this.base.io, if_cmd, &dummy_buf);
        if (res_len == 0) {
            if (this.hide_empty_text) {
                if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
            }
            return;
        }
    }

    const out = sh.runAlloc(this.base.io, this.base.allocator, this.exec_cmd) catch return;
    defer this.base.allocator.free(out);

    this.applyOutput(out);
}

pub fn applyOutput(this: *CustomModule, raw: []const u8) void {
    const trimmed = mem.trim(u8, raw, " \r\n\t");

    if (this.hide_empty_text and trimmed.len == 0) {
        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
        return;
    } else {
        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
    }

    if (trimmed.len == 0) return;

    if (this.return_type_json) {
        var parsed = json.parseFromSlice(json.Value, this.base.allocator, trimmed, .{}) catch {
            this.base.setText(trimmed);
            return;
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("text")) |txt| {
                if (txt == .string) {
                    if (this.hide_empty_text and txt.string.len == 0) {
                        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
                    } else {
                        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
                        this.base.setText(txt.string);
                    }
                }
            }
            if (obj.get("tooltip")) |tt| {
                if (tt == .string) this.base.setTooltip(tt.string);
            }
            if (obj.get("class")) |cls| {
                if (cls == .string) {
                    var c_buf: [128]u8 = undefined;
                    const len = @min(cls.string.len, c_buf.len - 1);
                    @memcpy(c_buf[0..len], cls.string[0..len]);
                    c_buf[len] = 0;
                    this.base.addCssClass(c_buf[0..len :0]);
                }
            }
            if (obj.get("percentage")) |pct| {
                var val: f64 = 0;
                if (pct == .integer) val = @floatFromInt(pct.integer) else if (pct == .float) val = pct.float;
                _ = this.base.applyState(val, false);
            }
        }
    } else {
        this.base.setText(trimmed);
    }
}

var signal_modules: [64]?SignalModuleNode = @splat(null);

pub fn registerSignalModule(sig: i32, mod: *CustomModule) void {
    for (&signal_modules) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .sig = sig, .module = mod };
            break;
        }
    }
}

pub fn unregisterSignalModule(sig: i32, mod: *CustomModule) void {
    for (&signal_modules) |*slot| {
        if (slot.*) |node| {
            if (node.sig == sig and node.module == mod) {
                slot.* = null;
                break;
            }
        }
    }
}

pub fn dispatchSignal(sig: i32) void {
    for (signal_modules) |slot| {
        if (slot) |node| {
            if (node.sig == sig) node.module.runOnce();
        }
    }
}

fn expandTilde(allocator: Allocator, path: []const u8) ![]const u8 {
    return try env.expandHomeAlloc(allocator, path);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *CustomModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.runOnce();
    return 1;
}

const StreamLineContext = struct {
    module: *CustomModule,
    line: []u8,

    fn onCallback(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
        const ctx: *StreamLineContext = @ptrCast(@alignCast(user_data orelse return 0));
        defer {
            ctx.module.base.allocator.free(ctx.line);
            ctx.module.base.allocator.destroy(ctx);
        }

        if (ctx.module.running.load(.seq_cst)) {
            ctx.module.applyOutput(ctx.line);
        }
        return 0;
    }
};

fn streamWorker(this: *CustomModule) void {
    const io = this.base.io;
    while (this.running.load(.seq_cst)) {
        if (this.exec_cmd.len == 0) break;

        var child = sh.spawnStream(io, this.exec_cmd) catch {
            sh.sleepSeconds(io, this.restart_interval_sec);
            continue;
        };
        defer if (child.id != null) child.kill(io);

        var io_buf: [4096]u8 = undefined;
        var f_reader = child.stdout.?.reader(io, &io_buf);

        while (this.running.load(.seq_cst)) {
            const line = f_reader.interface.takeDelimiterInclusive('\n') catch break;
            const copy = this.base.allocator.dupe(u8, line) catch continue;
            const ctx = this.base.allocator.create(StreamLineContext) catch {
                this.base.allocator.free(copy);
                continue;
            };
            ctx.* = .{
                .module = this,
                .line = copy,
            };
            _ = gtk.g_idle_add(@ptrCast(&StreamLineContext.onCallback), ctx);
        }

        sh.sleepSeconds(io, this.restart_interval_sec);
    }
}
