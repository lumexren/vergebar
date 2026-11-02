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
const ArrayList = std.ArrayList;
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;

pub const ClockModule = struct {
    base: *BaseModule,
    format: [:0]const u8,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*ClockModule {
        const self = try allocator.create(ClockModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "clock", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        const raw_fmt = settings.getString("format") orelse "  %H:%M:%S";
        const sanitized = try sanitizeClockFormat(allocator, raw_fmt);
        defer allocator.free(sanitized);

        self.format = try allocator.dupeSentinel(u8, sanitized, 0);
        self.interval_sec = @intCast(settings.getInt("interval") orelse 1);

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *ClockModule) void {
        if (self.timer_id != 0) _ = gtk.g_source_remove(self.timer_id);
        self.base.allocator.free(self.format);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn update(self: *ClockModule) void {
        const dt = gtk.g_date_time_new_now_local() orelse return;
        defer gtk.g_date_time_unref(dt);

        if (gtk.g_date_time_format(dt, self.format.ptr)) |formatted_ptr| {
            defer gtk.g_free(formatted_ptr);
            self.base.setText(mem.span(formatted_ptr));
        }

        const tt_fmt: [:0]const u8 = "%A, %B %d, %Y";
        if (gtk.g_date_time_format(dt, tt_fmt.ptr)) |tt_ptr| {
            defer gtk.g_free(tt_ptr);
            self.base.setTooltip(mem.span(tt_ptr));
        }
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *ClockModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}

fn sanitizeClockFormat(allocator: Allocator, raw: []const u8) ![]const u8 {
    var out: ArrayList(u8) = try .initCapacity(allocator, raw.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (i + 1 < raw.len and raw[i] == '{' and raw[i + 1] == ':') {
            i += 2;
            continue;
        }
        if (raw[i] == '}') {
            i += 1;
            continue;
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}
