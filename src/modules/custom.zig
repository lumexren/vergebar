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

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const Thread = std.Thread;
const atomic = std.atomic;
const json = std.json;
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;

const Context = @import("utils").Context;

pub const CustomModule = struct {
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

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*CustomModule {
        const self = try allocator.create(CustomModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, name, settings);
        errdefer base_mod.deinit();

        const raw_exec = settings.getString("exec") orelse "";
        const expanded_exec = try expandTilde(allocator, raw_exec);
        defer allocator.free(expanded_exec);

        const exec_if_str = settings.getString("exec-if");
        const expanded_exec_if = if (exec_if_str) |ei| try expandTilde(allocator, ei) else null;
        defer if (expanded_exec_if) |ei| allocator.free(ei);

        self.exec_cmd = try allocator.dupeSentinel(u8, expanded_exec, 0);
        self.exec_if_cmd = if (expanded_exec_if) |ei| try allocator.dupeSentinel(u8, ei, 0) else null;
        self.hide_empty_text = settings.getBool("hide-empty-text") orelse false;

        const rt = settings.getString("return-type") orelse "";
        self.return_type_json = mem.eql(u8, rt, "json");
        self.interval_sec = @intCast(settings.getInt("interval") orelse 0);
        self.restart_interval_sec = @intCast(settings.getInt("restart-interval") orelse 5);

        const sig_val = settings.getInt("signal");
        self.signal_num = if (sig_val) |s| @intCast(s) else null;

        self.* = .{
            .base = base_mod,
            .exec_cmd = self.exec_cmd,
            .exec_if_cmd = self.exec_if_cmd,
            .hide_empty_text = self.hide_empty_text,
            .return_type_json = self.return_type_json,
            .interval_sec = self.interval_sec,
            .restart_interval_sec = self.restart_interval_sec,
            .signal_num = self.signal_num,
        };

        if (self.signal_num) |sig| registerSignalModule(sig, self);

        if (self.interval_sec > 0 or self.signal_num != null) {
            self.runOnce();
            if (self.interval_sec > 0) self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);
        } else {
            self.stream_thread = Thread.spawn(.{}, streamWorker, .{self}) catch null;
        }

        return self;
    }

    pub fn deinit(self: *CustomModule) void {
        self.running.store(false, .seq_cst);
        if (self.signal_num) |sig| unregisterSignalModule(sig, self);
        if (self.timer_id != 0) _ = gtk.g_source_remove(self.timer_id);
        if (self.stream_thread) |thread| thread.detach();
        self.base.allocator.free(self.exec_cmd);
        if (self.exec_if_cmd) |ei| self.base.allocator.free(ei);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn runOnce(self: *CustomModule) void {
        if (self.exec_cmd.len == 0) return;

        if (self.exec_if_cmd) |if_cmd| {
            var dummy_buf: [1]u8 = undefined;
            const res_len = Context.runShellBuf(if_cmd, &dummy_buf);
            if (res_len == 0) {
                if (self.hide_empty_text) {
                    if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
                }
                return;
            }
        }

        const out = Context.runShellAlloc(self.base.allocator, self.exec_cmd) catch return;
        defer self.base.allocator.free(out);

        self.applyOutput(out);
    }

    pub fn applyOutput(self: *CustomModule, raw: []const u8) void {
        const trimmed = mem.trim(u8, raw, " \r\n\t");

        if (self.hide_empty_text and trimmed.len == 0) {
            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
            return;
        } else {
            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
        }

        if (trimmed.len == 0) return;

        if (self.return_type_json) {
            var parsed = json.parseFromSlice(json.Value, self.base.allocator, trimmed, .{}) catch {
                self.base.setText(trimmed);
                return;
            };
            defer parsed.deinit();

            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (obj.get("text")) |txt| {
                    if (txt == .string) {
                        if (self.hide_empty_text and txt.string.len == 0) {
                            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
                        } else {
                            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
                            self.base.setText(txt.string);
                        }
                    }
                }
                if (obj.get("tooltip")) |tt| {
                    if (tt == .string) self.base.setTooltip(tt.string);
                }
                if (obj.get("class")) |cls| {
                    if (cls == .string) {
                        var c_buf: [128]u8 = undefined;
                        const len = @min(cls.string.len, c_buf.len - 1);
                        @memcpy(c_buf[0..len], cls.string[0..len]);
                        c_buf[len] = 0;
                        self.base.addCssClass(c_buf[0..len :0]);
                    }
                }
                if (obj.get("percentage")) |pct| {
                    var val: f64 = 0;
                    if (pct == .integer) val = @floatFromInt(pct.integer) else if (pct == .float) val = pct.float;
                    _ = self.base.applyState(val, false);
                }
            }
        } else {
            self.base.setText(trimmed);
        }
    }
};

const SignalModuleNode = struct {
    sig: i32,
    module: *CustomModule,
};

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
    return try Context.expandHomeAlloc(allocator, path);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *CustomModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.runOnce();
    return 1;
}

fn streamWorker(self: *CustomModule) void {
    const ctx = Context.get() orelse return;
    while (self.running.load(.seq_cst)) {
        if (self.exec_cmd.len == 0) break;

        var child = Context.spawnShellStream(self.exec_cmd) catch {
            Context.sleepSeconds(self.restart_interval_sec);
            continue;
        };
        defer if (child.id != null) child.kill(ctx.io);

        var io_buf: [4096]u8 = undefined;
        var f_reader = child.stdout.?.reader(ctx.io, &io_buf);

        while (self.running.load(.seq_cst)) {
            const line = f_reader.interface.takeDelimiterInclusive('\n') catch break;
            const copy = self.base.allocator.dupe(u8, line) catch continue;
            _ = gtk.g_idle_add(@ptrCast(&onStreamOutput), @ptrCast(@alignCast(@constCast(copy.ptr))));
        }

        Context.sleepSeconds(self.restart_interval_sec);
    }
}

fn onStreamOutput(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const ptr: [*:0]u8 = @ptrCast(user_data orelse return 0);
    _ = ptr;
    return 0;
}
