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

pub const TemperatureModule = struct {
    base: *BaseModule,
    temp: sysinfo.Temperature,
    format: []const u8,
    icon: []const u8,
    warning_threshold: f64,
    critical_threshold: f64,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*TemperatureModule {
        const self = try allocator.create(TemperatureModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "temperature", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.temp = sysinfo.Temperature.init(io, allocator, null);
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{icon}  {temperature_c}°C");
        self.icon = try allocator.dupe(u8, settings.getString("icon") orelse "");
        self.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 75.0);
        self.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
        self.interval_sec = @intCast(settings.getInt("interval") orelse 2);

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *TemperatureModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
        }
        self.temp.deinit();
        self.base.allocator.free(self.format);
        self.base.allocator.free(self.icon);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn update(self: *TemperatureModule) void {
        self.temp.update() catch return;

        var cur_temp: f64 = self.temp.info.celsius;
        if (cur_temp <= 0 and self.temp.sensors.items.len > 0) {
            for (self.temp.sensors.items) |sensor| {
                if (sensor.celsius > cur_temp) cur_temp = sensor.celsius;
            }
        }

        const temp_int: i64 = @intFromFloat(@round(cur_temp));

        var replacer: Replacer = .init(self.base.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", self.icon) catch {};
        replacer.addKeyAny("temperature_c", temp_int) catch {};
        replacer.addKeyAny("temperature_f", @as(i64, @intFromFloat(@round(cur_temp * 9.0 / 5.0 + 32.0)))) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.base.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "Temperature: {d:.1}°C", .{cur_temp}) catch "Temperature";
        self.base.setTooltip(tt);

        const is_warning = cur_temp >= self.warning_threshold and cur_temp < self.critical_threshold;
        const is_critical = cur_temp >= self.critical_threshold;
        self.base.setClasses(is_warning, is_critical);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *TemperatureModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
