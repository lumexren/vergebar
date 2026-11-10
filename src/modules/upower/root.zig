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

const UPowerModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const gdbus = @import("bindings").gdbus;
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const Template = @import("utils").Template;

const UPOWER_SERVICE = "org.freedesktop.UPower";
const DISPLAY_DEVICE_PATH = "/org/freedesktop/UPower/devices/DisplayDevice";
const DEVICE_IFACE = "org.freedesktop.UPower.Device";

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
format: []const u8,
dbus_conn: ?*gdbus.GDBusConnection = null,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*UPowerModule {
    const this = try allocator.create(UPowerModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "upower", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getString("format") orelse "{percentage}%";
    var tmpl: Template = try .compile(allocator, format_str);
    errdefer tmpl.deinit();

    const conn = gdbus.getBus(.system);

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .template = tmpl,
        .template_tooltip = if (base_mod.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null,
        .format = try allocator.dupe(u8, format_str),
        .dbus_conn = conn,
    };

    this.update();
    this.timer_id = gtk.g_timeout_add_seconds(10, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *UPowerModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    this.allocator.free(this.format);
    if (this.dbus_conn) |c| gdbus.g_object_unref(c);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *UPowerModule) void {
    const c = this.dbus_conn orelse return;

    var percentage: f64 = 100.0;
    var state_code: u32 = 0;
    var time_to_empty: i64 = 0;
    var time_to_full: i64 = 0;

    if (gdbus.getPropertySync(c, UPOWER_SERVICE, DISPLAY_DEVICE_PATH, DEVICE_IFACE, "Percentage")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asDouble(v)) |p| percentage = p;
    }

    if (gdbus.getPropertySync(c, UPOWER_SERVICE, DISPLAY_DEVICE_PATH, DEVICE_IFACE, "State")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asUint32(v)) |s| state_code = s;
    }

    if (gdbus.getPropertySync(c, UPOWER_SERVICE, DISPLAY_DEVICE_PATH, DEVICE_IFACE, "TimeToEmpty")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asInt64(v)) |t| time_to_empty = t;
    }

    if (gdbus.getPropertySync(c, UPOWER_SERVICE, DISPLAY_DEVICE_PATH, DEVICE_IFACE, "TimeToFull")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asInt64(v)) |t| time_to_full = t;
    }

    const state_str: []const u8 = switch (state_code) {
        1 => "Charging",
        2 => "Discharging",
        3 => "Empty",
        4 => "Full",
        5 => "Pending Charge",
        6 => "Pending Discharge",
        else => "Unknown",
    };

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKeyAny("percentage", @as(i64, @intFromFloat(percentage))) catch {};
    replacer.addKey("state", state_str) catch {};

    if (time_to_empty > 0) {
        var t_buf: [16]u8 = undefined;
        const mins = @divTrunc(time_to_empty, 60);
        const t_str = mem.print(&t_buf, "{d:0>2}:{d:0>2}", .{ @divTrunc(mins, 60), @mod(mins, 60) }) catch "";
        replacer.addKey("time", t_str) catch {};
    } else if (time_to_full > 0) {
        var t_buf: [16]u8 = undefined;
        const mins = @divTrunc(time_to_full, 60);
        const t_str = mem.print(&t_buf, "{d:0>2}:{d:0>2}", .{ @divTrunc(mins, 60), @mod(mins, 60) }) catch "";
        replacer.addKey("time", t_str) catch {};
    } else {
        replacer.addKey("time", "") catch {};
    }

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
        const tt = mem.print(&tt_buf, "UPower Display Device: {d:.0}% ({s})", .{ percentage, state_str }) catch "UPower";
        this.base.setTooltip(tt);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *UPowerModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
