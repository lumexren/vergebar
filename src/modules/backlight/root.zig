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

const BacklightModule = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;
const sysinfo = @import("sysinfo");
const gdbus = @import("bindings").gdbus;

base: *BaseModule,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
device: ?[]const u8 = null,
scroll_step: f64,
interval_sec: u32,
timer_id: u32 = 0,
sync_timer_id: u32 = 0,
last_percentage: ?u8 = null,
system_bus: ?*gdbus.GDBusConnection = null,
detected_device: [64]u8 = @splat(0),
detected_device_len: u8 = 0,
max_brightness: u32 = 100,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*BacklightModule {
    const this = try allocator.create(BacklightModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "backlight", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {percentage}%");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", ""));
    this.device = if (settings.getString("device")) |d| try allocator.dupe(u8, d) else null;
    this.scroll_step = @floatFromInt(settings.getInt("scroll-step") orelse 5);
    if (this.scroll_step <= 0) this.scroll_step = 5.0;
    this.interval_sec = settings.getOr(u32, "interval", 2);

    this.system_bus = gdbus.getBus(.system);
    this.detected_device = @splat(0);
    this.detected_device_len = 0;
    this.max_brightness = 100;

    this.base.custom_scroll_handler = &onScroll;
    this.base.custom_scroll_data = this;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *BacklightModule) void {
    const alloc = this.base.allocator;
    if (this.timer_id != 0) _ = gtk.g_source_remove(this.timer_id);
    if (this.sync_timer_id != 0) _ = gtk.g_source_remove(this.sync_timer_id);
    if (this.system_bus) |b| gdbus.g_object_unref(b);
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    if (this.device) |d| alloc.free(d);
    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn renderPercentage(this: *BacklightModule, percentage: u8) void {
    this.replacer.clear();

    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKeyAny("percentage", percentage) catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [128]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [64]u8 = undefined;
        const tt = mem.print(&tt_buf, "Brightness: {d}%", .{percentage}) catch "Backlight";
        this.base.setTooltip(tt);
    }
}

pub fn update(this: *BacklightModule) void {
    var percentage: u8 = 100;
    if (sysinfo.Backlight.readBrightness(this.base.io, this.device)) |stat| {
        percentage = stat.percentage;
        this.max_brightness = stat.max_brightness;
        const name_slice = stat.getName();
        const n_len = @min(name_slice.len, this.detected_device.len);
        @memcpy(this.detected_device[0..n_len], name_slice[0..n_len]);
        this.detected_device_len = @intCast(n_len);
    }

    this.last_percentage = percentage;
    this.renderPercentage(percentage);
}

fn onSyncTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *BacklightModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.sync_timer_id = 0;
    this.update();
    return 0;
}

pub fn adjustBrightness(this: *BacklightModule, step_percent: f64) void {
    const current_pct = this.last_percentage orelse 50;
    const step_i32: i32 = @intFromFloat(step_percent);
    const new_pct_i32 = @as(i32, current_pct) + step_i32;
    const clamped_pct: u8 = @intCast(std.math.clamp(new_pct_i32, 1, 100));
    this.last_percentage = clamped_pct;

    this.renderPercentage(clamped_pct);

    if (this.system_bus) |bus| {
        const dev_name = if (this.device) |d| d else this.detected_device[0..this.detected_device_len];
        if (dev_name.len > 0 and this.max_brightness > 0) {
            const target_val = (@as(u64, clamped_pct) * this.max_brightness) / 100;
            var arg_buf: [128]u8 = undefined;
            const arg_z = mem.printSentinel(&arg_buf, "('backlight', '{s}', @u {d})", .{ dev_name, target_val }, 0) catch "";
            if (arg_z.len > 0) {
                if (gdbus.g_variant_new_parsed(arg_z)) |params| {
                    gdbus.callMethodFireAndForget(
                        bus,
                        "org.freedesktop.login1",
                        "/org/freedesktop/login1/session/auto",
                        "org.freedesktop.login1.Session",
                        "SetBrightness",
                        params,
                    );
                    if (this.sync_timer_id != 0) _ = gtk.g_source_remove(this.sync_timer_id);
                    this.sync_timer_id = gtk.g_timeout_add(150, @ptrCast(&onSyncTimeout), this);
                    return;
                }
            }
        }
    }

    var buf: [128]u8 = undefined;
    const dev_arg = if (this.device) |d| d else "";
    const printed = if (step_percent >= 0)
        (if (this.device != null)
            mem.print(&buf, "brightnessctl -d {s} set {d}%+\x00", .{ dev_arg, @as(u32, @intFromFloat(step_percent)) })
        else
            mem.print(&buf, "brightnessctl set {d}%+\x00", .{@as(u32, @intFromFloat(step_percent))})) catch return
    else
        (if (this.device != null)
            mem.print(&buf, "brightnessctl -d {s} set {d}%-\x00", .{ dev_arg, @as(u32, @intFromFloat(@abs(step_percent))) })
        else
            mem.print(&buf, "brightnessctl set {d}%-\x00", .{@as(u32, @intFromFloat(@abs(step_percent)))})) catch return;

    _ = gtk.g_spawn_command_line_async(@ptrCast(printed.ptr), null);

    if (this.sync_timer_id != 0) {
        _ = gtk.g_source_remove(this.sync_timer_id);
    }
    this.sync_timer_id = gtk.g_timeout_add(150, @ptrCast(&onSyncTimeout), this);
}

fn onScroll(user_data: ?*anyopaque, dy: f64) void {
    const this: *BacklightModule = @ptrCast(@alignCast(user_data orelse return));
    if (dy < 0) {
        this.adjustBrightness(this.scroll_step);
    } else if (dy > 0) {
        this.adjustBrightness(-this.scroll_step);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *BacklightModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
