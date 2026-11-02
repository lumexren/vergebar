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
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

pub const UserModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*UserModule {
        const self = try allocator.create(UserModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "user", settings);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "{user} ↑ {work_H}h {work_M}m";
        const interval = @as(u32, @intCast(settings.getInt("interval") orelse 60));

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, format_str),
            .interval_sec = interval,
        };

        self.update();
        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *UserModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *UserModule) void {
        const Context = @import("utils").Context;
        const username = Context.getEnv("USER") orelse "user";

        var uptime_sec: u64 = 0;
        var buf: [32]u8 = undefined;
        if (Context.readSysfsLine("/proc/uptime", &buf)) |line| {
            var tokens = mem.tokenizeScalar(u8, line, ' ');
            if (tokens.next()) |up_str| {
                const up_float = fmt.parseFloat(f64, up_str) catch 0.0;
                uptime_sec = @intFromFloat(up_float);
            }
        }

        const days = uptime_sec / 86400;
        const hours = (uptime_sec % 86400) / 3600;
        const minutes = (uptime_sec % 3600) / 60;

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("user", username) catch {};
        replacer.addKeyAny("work_d", @as(i64, @intCast(days))) catch {};
        replacer.addKeyAny("work_H", @as(i64, @intCast(hours))) catch {};
        replacer.addKeyAny("work_M", @as(i64, @intCast(minutes))) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "User: {s} | Uptime: {d}d {d}h {d}m", .{ username, days, hours, minutes }) catch "User";
        self.base.setTooltip(tt);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *UserModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
