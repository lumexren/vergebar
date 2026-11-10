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

const UpdatesModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;
const atomic = std.atomic;
const process = std.process;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;

base: *BaseModule,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,
worker_thread: ?Thread = null,
running: atomic.Value(bool) = .init(true),
updating: atomic.Value(bool) = .init(false),
total_updates: atomic.Value(usize) = .init(0),
manager_name_buf: [32]u8 = @splat(0),
manager_name_len: usize = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*UpdatesModule {
    const this = try allocator.create(UpdatesModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "updates", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {total_updates}");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", "󰚰"));
    this.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 1.0);
    this.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 50.0);
    this.interval_sec = settings.getOr(u32, "interval", 300); // 5 minutes default

    this.base.custom_click_handler = &onCustomClick;
    this.base.custom_click_data = this;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    this.triggerCheck();

    return this;
}

pub fn deinit(this: *UpdatesModule) void {
    const alloc = this.base.allocator;
    this.running.store(false, .seq_cst);
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
    }
    if (this.worker_thread) |thread| {
        thread.join();
        this.worker_thread = null;
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

fn triggerCheck(this: *UpdatesModule) void {
    if (this.updating.swap(true, .seq_cst)) return;
    if (this.worker_thread) |thread| {
        thread.join();
        this.worker_thread = null;
    }
    this.worker_thread = Thread.spawn(.{}, workerThreadFn, .{this}) catch null;
    if (this.worker_thread == null) {
        this.updating.store(false, .seq_cst);
    }
}

fn workerThreadFn(this: *UpdatesModule) void {
    defer this.updating.store(false, .seq_cst);

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var env_map: process.Environ.Map = .init(this.base.allocator);
    defer env_map.deinit();

    if (utils.env.get("PATH")) |p| {
        env_map.put("PATH", p) catch {};
    }

    const mgr = sysinfo.Updates.getManager(io, this.base.allocator, &env_map) catch return;
    const m_name = mgr.name();
    const copy_len = @min(m_name.len, this.manager_name_buf.len);
    @memcpy(this.manager_name_buf[0..copy_len], m_name[0..copy_len]);
    this.manager_name_len = copy_len;

    var checker: sysinfo.Updates = .init(io, this.base.allocator, &env_map, mgr);
    defer checker.deinit();

    checker.check() catch return;

    this.total_updates.store(checker.count, .seq_cst);

    _ = gtk.g_idle_add(@ptrCast(&onIdleUpdate), this);
}

fn onIdleUpdate(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *UpdatesModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 0; // run once
}

pub fn update(this: *UpdatesModule) void {
    const count = this.total_updates.load(.seq_cst);
    const count_i64: i64 = @intCast(count);
    const count_f64: f64 = @floatFromInt(count);

    this.replacer.clear();
    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKeyAny("total_updates", count_i64) catch {};
    this.replacer.addKeyAny("count", count_i64) catch {};
    const m_name = if (this.manager_name_len > 0) this.manager_name_buf[0..this.manager_name_len] else "packages";
    this.replacer.addKey("manager", m_name) catch {};

    var render_buf: [256]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [512]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "{d} package updates available via {s}", .{
            count,
            m_name,
        }) catch "Updates";
        this.base.setTooltip(tt);
    }

    const is_warning = count_f64 >= this.warning_threshold and count_f64 < this.critical_threshold;
    const is_critical = count_f64 >= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(count_f64, false);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *UpdatesModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.triggerCheck();
    return 1;
}

fn onCustomClick(user_data: ?*anyopaque, button: c_uint) bool {
    const this: *UpdatesModule = @ptrCast(@alignCast(user_data orelse return false));

    if (button == 1) { // Left click: open terminal and run upgrade command
        const m_name = if (this.manager_name_len > 0) this.manager_name_buf[0..this.manager_name_len] else "pacman";
        var cmd_buf: [256]u8 = undefined;
        const upgrade_cmd = if (mem.eql(u8, m_name, "yay"))
            "yay -Syu"
        else if (mem.eql(u8, m_name, "paru"))
            "paru -Syu"
        else if (mem.eql(u8, m_name, "pacman"))
            "sudo pacman -Syu"
        else if (mem.eql(u8, m_name, "dnf"))
            "sudo dnf upgrade"
        else if (mem.eql(u8, m_name, "apt"))
            "sudo apt update && sudo apt upgrade"
        else if (mem.eql(u8, m_name, "zypper"))
            "sudo zypper dup"
        else if (mem.eql(u8, m_name, "xbps"))
            "sudo xbps-install -Su"
        else if (mem.eql(u8, m_name, "flatpak"))
            "flatpak update"
        else
            "sudo pacman -Syu";

        // Try standard terminal emulators
        const term = utils.env.get("TERMINAL") orelse "xterm";
        const spawn_cmd = mem.printSentinel(&cmd_buf, "{s} -e sh -c \"{s}; echo Press Enter to exit; read dummy\"", .{ term, upgrade_cmd }, 0) catch return false;
        _ = gtk.g_spawn_command_line_async(spawn_cmd.ptr, null);
        return true;
    } else if (button == 3) { // Right click: force refresh now
        this.triggerCheck();
        return true;
    }

    return false;
}
