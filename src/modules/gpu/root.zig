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

const GpuModule = @This();

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
gpu: sysinfo.GPU,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*GpuModule {
    const this = try allocator.create(GpuModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "gpu", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {usage}%");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    var gpu: sysinfo.GPU = .initWithIo(io, allocator);
    if (settings.getString("backend")) |backend_str| {
        gpu.setBackend(.fromString(backend_str));
    }
    if (settings.getInt("device_index") orelse settings.getInt("device-index")) |idx| {
        gpu.setDeviceIndex(@intCast(idx));
    }
    _ = gpu.initialize() catch {};

    this.gpu = gpu;
    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", "󰢮"));
    this.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 75.0);
    this.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
    this.interval_sec = settings.getOr(u32, "interval", 2);

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *GpuModule) void {
    const alloc = this.base.allocator;
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    this.gpu.deinit();
    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *GpuModule) void {
    const info = this.gpu.getInfo() catch {
        this.base.setText("GPU N/A");
        return;
    };

    const usage_pct = @as(f64, @floatFromInt(info.gpu_busy));
    const usage_int: i64 = @intCast(info.gpu_busy);
    const vram_pct = info.memory_info.percentage();

    this.replacer.clear();
    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKeyAny("usage", usage_int) catch {};
    this.replacer.addKeyAny("usage_percentage", usage_int) catch {};
    this.replacer.addKeyAny("temperature", @as(f64, @floatCast(info.temperature))) catch {};
    this.replacer.addKeyAny("pwm_percentage", @as(i64, @intCast(info.pwm))) catch {};
    this.replacer.addKeyAny("vram_percentage", @as(i64, @intCast(vram_pct))) catch {};
    this.replacer.addKeyAny("vram_used", @as(i64, @intCast(info.memory_info.used))) catch {};
    this.replacer.addKeyAny("vram_total", @as(i64, @intCast(info.memory_info.total))) catch {};
    this.replacer.addKeyAny("vram_free", @as(i64, @intCast(info.memory_info.free))) catch {};

    if (info.getName()) |n| {
        this.replacer.addKey("device_name", n) catch {};
    } else {
        this.replacer.addKey("device_name", "GPU") catch {};
    }
    this.replacer.addKey("backend", info.backend_name) catch {};

    if (info.power_usage) |p| this.replacer.addKeyAny("power_usage", @as(f64, @floatCast(p))) catch {};
    if (info.power_limit) |pl| this.replacer.addKeyAny("power_limit", @as(f64, @floatCast(pl))) catch {};
    if (info.clock_speed) |clk| this.replacer.addKeyAny("clock_speed", @as(i64, @intCast(clk))) catch {};

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
        const dev_name = info.getName() orelse "GPU";
        const tt = mem.print(&tt_buf, "{s}\nUsage: {d}%\nVRAM: {d}% ({d}/{d} MB)\nTemp: {d:.1}°C", .{
            dev_name,
            usage_int,
            vram_pct,
            info.memory_info.used / (1024 * 1024),
            info.memory_info.total / (1024 * 1024),
            info.temperature,
        }) catch "GPU";
        this.base.setTooltip(tt);
    }

    const is_warning = usage_pct >= this.warning_threshold and usage_pct < this.critical_threshold;
    const is_critical = usage_pct >= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(usage_pct, false);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *GpuModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
