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

const TemperatureModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const fmt = std.fmt;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;

base: *BaseModule,
temp: sysinfo.Temperature,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*TemperatureModule {
    const this = try allocator.create(TemperatureModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "temperature", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {temperature_c}°C");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.temp = .init(io, allocator, null);
    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", ""));
    this.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 75.0);
    this.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
    this.interval_sec = settings.getOr(u32, "interval", 2);

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *TemperatureModule) void {
    const alloc = this.base.allocator;
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    this.temp.deinit();
    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *TemperatureModule) void {
    this.temp.update() catch return;

    var cur_temp: f64 = this.temp.info.celsius;
    if (cur_temp <= 0 and this.temp.sensors.items.len > 0) {
        for (this.temp.sensors.items) |sensor| {
            if (sensor.celsius > cur_temp) cur_temp = sensor.celsius;
        }
    }

    const temp_int: i64 = @intFromFloat(@round(cur_temp));

    this.replacer.clear();

    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKeyAny("temperature_c", temp_int) catch {};
    this.replacer.addKeyAny("temperature_f", @as(i64, @intFromFloat(@round(cur_temp * 9.0 / 5.0 + 32.0)))) catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "Temperature: {d:.1}°C", .{cur_temp}) catch "Temperature";
        this.base.setTooltip(tt);
    }

    const is_warning = cur_temp >= this.warning_threshold and cur_temp < this.critical_threshold;
    const is_critical = cur_temp >= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(cur_temp, false);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *TemperatureModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
