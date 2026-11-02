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
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Context = utils.Context;

pub const BatteryModule = struct {
    base: *BaseModule,
    format: []const u8,
    icon: []const u8,
    warning_threshold: f64,
    critical_threshold: f64,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*BatteryModule {
        const self = try allocator.create(BatteryModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "battery", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{icon}  {percentage}%");
        self.icon = try allocator.dupe(u8, settings.getString("icon") orelse "");
        self.warning_threshold = settings.getFloat("warning-threshold") orelse 20.0;
        self.critical_threshold = settings.getFloat("critical-threshold") orelse 10.0;
        self.interval_sec = @intCast(settings.getInt("interval") orelse 5);

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *BatteryModule) void {
        if (self.timer_id != 0) _ = gtk.g_source_remove(self.timer_id);
        self.base.allocator.free(self.format);
        self.base.allocator.free(self.icon);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn update(self: *BatteryModule) void {
        var capacity: i64 = 100;
        var status_buf: [32]u8 = undefined;
        var status_str: []const u8 = "Full";

        var cap_buf: [16]u8 = undefined;
        const cap_line = Context.readSysfsLine("/sys/class/power_supply/BAT0/capacity", &cap_buf) orelse Context.readSysfsLine("/sys/class/power_supply/BAT1/capacity", &cap_buf);
        if (cap_line) |s| capacity = fmt.parseInt(i64, s, 10) catch 100;

        const stat_line = Context.readSysfsLine("/sys/class/power_supply/BAT0/status", &status_buf) orelse Context.readSysfsLine("/sys/class/power_supply/BAT1/status", &status_buf);
        if (stat_line) |s| status_str = s;

        var replacer: Replacer = .init(self.base.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", self.icon) catch {};
        replacer.addKeyAny("percentage", capacity) catch {};
        replacer.addKey("state", status_str) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.base.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "Battery: {s} ({d}%)", .{ status_str, capacity }) catch "Battery";
        self.base.setTooltip(tt);

        const cap_pct: f64 = @floatFromInt(capacity);
        const is_warning = cap_pct <= self.warning_threshold and cap_pct > self.critical_threshold;
        const is_critical = cap_pct <= self.critical_threshold;
        self.base.setClasses(is_warning, is_critical);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *BatteryModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
