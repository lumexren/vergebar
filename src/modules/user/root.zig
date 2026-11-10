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

const UserModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const fmt = std.fmt;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const Template = @import("utils").Template;
const env = @import("utils").env;
const sysfs = @import("utils").sysfs;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
format: []const u8,
interval_sec: u32,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*UserModule {
    const this = try allocator.create(UserModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "user", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getString("format") orelse "{user} ↑ {work_H}h {work_M}m";
    var tmpl: Template = try .compile(allocator, format_str);
    errdefer tmpl.deinit();

    const interval = @as(u32, @intCast(settings.getInt("interval") orelse 60));

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .template = tmpl,
        .template_tooltip = if (base_mod.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null,
        .format = try allocator.dupe(u8, format_str),
        .interval_sec = interval,
    };

    this.update();
    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *UserModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *UserModule) void {
    const username = env.get("USER") orelse "user";

    var uptime_sec: u64 = 0;
    var buf: [32]u8 = undefined;
    if (sysfs.readLine(this.base.io, "/proc/uptime", &buf)) |line| {
        var tokens = mem.tokenizeScalar(u8, line, ' ');
        if (tokens.next()) |up_str| {
            const up_float = fmt.parseFloat(f64, up_str) catch 0.0;
            uptime_sec = @intFromFloat(up_float);
        }
    }

    const days = uptime_sec / 86400;
    const hours = (uptime_sec % 86400) / 3600;
    const minutes = (uptime_sec % 3600) / 60;

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKey("user", username) catch {};
    replacer.addKeyAny("work_d", @as(i64, @intCast(days))) catch {};
    replacer.addKeyAny("work_H", @as(i64, @intCast(hours))) catch {};
    replacer.addKeyAny("work_M", @as(i64, @intCast(minutes))) catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = this.template.renderBuf(replacer, &render_buf) catch this.format;
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "User: {s} | Uptime: {d}d {d}h {d}m", .{ username, days, hours, minutes }) catch "User";
        this.base.setTooltip(tt);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *UserModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
