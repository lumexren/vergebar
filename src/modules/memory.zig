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
const Io = std.Io;
const fmt = std.fmt;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

pub const MemoryModule = struct {
    base: *BaseModule,
    memory: sysinfo.Memory,
    format: []const u8,
    icon: []const u8,
    warning_threshold: f64,
    critical_threshold: f64,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*MemoryModule {
        const self = try allocator.create(MemoryModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "memory", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.memory = sysinfo.Memory.init(io);
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{icon}  {percentage}%");
        self.icon = try allocator.dupe(u8, settings.getString("icon") orelse "");
        self.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 75.0);
        self.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
        self.interval_sec = @intCast(settings.getInt("interval") orelse 2);

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *MemoryModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
        }
        self.base.allocator.free(self.format);
        self.base.allocator.free(self.icon);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn update(self: *MemoryModule) void {
        self.memory.update() catch return;

        const used_pct: f64 = if (self.memory.physical.total > 0)
            (@as(f64, @floatFromInt(self.memory.physical.used)) / @as(f64, @floatFromInt(self.memory.physical.total))) * 100.0
        else
            0.0;
        const used_pct_int: i64 = @intFromFloat(@round(used_pct));

        const used_gb = @as(f64, @floatFromInt(self.memory.physical.used)) / 1024.0 / 1024.0 / 1024.0;
        const total_gb = @as(f64, @floatFromInt(self.memory.physical.total)) / 1024.0 / 1024.0 / 1024.0;
        const avail_gb = @as(f64, @floatFromInt(self.memory.physical.available)) / 1024.0 / 1024.0 / 1024.0;

        var replacer: Replacer = .init(self.base.allocator);
        defer replacer.deinit();

        const swap_pct: f64 = if (self.memory.swap.total > 0)
            (@as(f64, @floatFromInt(self.memory.swap.used)) / @as(f64, @floatFromInt(self.memory.swap.total))) * 100.0
        else
            0.0;

        replacer.addKey("icon", self.icon) catch {};
        replacer.addKeyAny("percentage", used_pct_int) catch {};
        replacer.addKeyAny("used_percentage", used_pct_int) catch {};
        replacer.addKeyAny("used", used_gb) catch {};
        replacer.addKeyAny("total", total_gb) catch {};
        replacer.addKeyAny("available", avail_gb) catch {};
        replacer.addKeyAny("swap_percentage", @as(i64, @intFromFloat(@round(swap_pct)))) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.base.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [512]u8 = undefined;
        const tt = mem.print(&tt_buf, "RAM: {d:.2} GiB / {d:.2} GiB ({d:.1}%)\nAvailable: {d:.2} GiB\nSwap: {d:.1}%", .{
            used_gb,
            total_gb,
            used_pct,
            avail_gb,
            swap_pct,
        }) catch "Memory";
        self.base.setTooltip(tt);

        const is_warning = used_pct >= self.warning_threshold and used_pct < self.critical_threshold;
        const is_critical = used_pct >= self.critical_threshold;
        self.base.setClasses(is_warning, is_critical);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *MemoryModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
