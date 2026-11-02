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

pub const LoadModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*LoadModule {
        const self = try allocator.create(LoadModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "load", settings);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "{load1}";
        const interval = @as(u32, @intCast(settings.getInt("interval") orelse 10));

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

    pub fn deinit(self: *LoadModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *LoadModule) void {
        const Context = @import("utils").Context;

        var buf: [64]u8 = undefined;
        const line = Context.readSysfsLine("/proc/loadavg", &buf) orelse return;

        var tokens = mem.tokenizeScalar(u8, line, ' ');
        const l1 = tokens.next() orelse "0.00";
        const l5 = tokens.next() orelse "0.00";
        const l15 = tokens.next() orelse "0.00";

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("load1", l1) catch {};
        replacer.addKey("load5", l5) catch {};
        replacer.addKey("load15", l15) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "Load average: {s}, {s}, {s}", .{ l1, l5, l15 }) catch "Load";
        self.base.setTooltip(tt);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *LoadModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
