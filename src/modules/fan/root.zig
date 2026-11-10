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

const FanModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;

base: *BaseModule,
fan_list: ArrayList(sysinfo.Fan.FanInfo),
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*FanModule {
    const this = try allocator.create(FanModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "fan", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {speed} RPM");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.fan_list = .empty;
    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", "󰈐"));
    this.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 3500.0);
    this.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 5000.0);
    this.interval_sec = settings.getOr(u32, "interval", 2);

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *FanModule) void {
    const alloc = this.base.allocator;
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();

    for (this.fan_list.items) |f| alloc.free(f.name);
    this.fan_list.deinit(alloc);

    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *FanModule) void {
    for (this.fan_list.items) |f| this.base.allocator.free(f.name);
    this.fan_list.clearRetainingCapacity();

    const fan_scanner: sysinfo.Fan = .init(this.base.io, this.base.allocator, &this.fan_list);
    fan_scanner.scan() catch {};

    var max_speed: i64 = 0;
    var primary_name: []const u8 = "Fan";
    for (this.fan_list.items) |f| {
        if (f.speed > max_speed) {
            max_speed = f.speed;
            primary_name = f.name;
        }
    }

    this.replacer.clear();
    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKeyAny("speed", max_speed) catch {};
    this.replacer.addKeyAny("total_fans", @as(i64, @intCast(this.fan_list.items.len))) catch {};
    this.replacer.addKey("name", primary_name) catch {};

    var render_buf: [256]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [512]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [512]u8 = undefined;
        var pos: usize = 0;
        const h_slice = mem.print(tt_buf[pos..], "Total Fans: {d}\n", .{this.fan_list.items.len}) catch "";
        pos += h_slice.len;
        for (this.fan_list.items) |f| {
            if (pos >= tt_buf.len) break;
            const l_slice = mem.print(tt_buf[pos..], "{s}: {d} RPM\n", .{ f.name, f.speed }) catch break;
            pos += l_slice.len;
        }
        this.base.setTooltip(if (pos > 0) tt_buf[0..pos] else "Fans");
    }

    const speed_f64: f64 = @floatFromInt(max_speed);
    const is_warning = speed_f64 >= this.warning_threshold and speed_f64 < this.critical_threshold;
    const is_critical = speed_f64 >= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(speed_f64, false);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *FanModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
