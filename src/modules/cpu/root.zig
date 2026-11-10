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

const CpuModule = @This();

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
cpu: sysinfo.CPU,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,
popover: ?*gtk.GtkWidget = null,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*CpuModule {
    const this = try allocator.create(CpuModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "cpu", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {usage}%");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.cpu = .init(io, allocator);
    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", ""));
    this.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 70.0);
    this.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
    this.interval_sec = settings.getOr(u32, "interval", 1);

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *CpuModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    const alloc = this.base.allocator;
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    this.cpu.deinit();
    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *CpuModule) void {
    this.cpu.update() catch return;

    const usage_pct = this.cpu.avg;
    const usage_int: i64 = @intFromFloat(@round(usage_pct));

    var max_freq_ghz: f64 = 0.0;
    var sum_freq_ghz: f64 = 0.0;
    var freq_count: usize = 0;
    for (this.cpu.cores) |core| {
        const freq_ghz = if (mem.eql(u8, core.frequency.current.unit, "GHz"))
            core.frequency.current.value.raw
        else
            core.frequency.current.value.raw / 1000.0;

        if (freq_ghz > 0.0) {
            if (freq_ghz > max_freq_ghz) max_freq_ghz = freq_ghz;
            sum_freq_ghz += freq_ghz;
            freq_count += 1;
        }
    }
    const avg_freq_ghz = if (freq_count > 0) sum_freq_ghz / @as(f64, @floatFromInt(freq_count)) else 0.0;

    this.replacer.clear();

    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKeyAny("usage", usage_int) catch {};
    this.replacer.addKeyAny("usage_percentage", usage_int) catch {};
    this.replacer.addKeyAny("cores", this.cpu.cores.len) catch {};
    this.replacer.addKeyAny("frequency", avg_freq_ghz) catch {};
    this.replacer.addKeyAny("avg_frequency", avg_freq_ghz) catch {};
    this.replacer.addKeyAny("max_frequency", max_freq_ghz) catch {};
    this.replacer.addKeyAny("load_one", this.cpu.load_avg.one) catch {};
    this.replacer.addKeyAny("load_five", this.cpu.load_avg.five) catch {};
    this.replacer.addKeyAny("load_fifteen", this.cpu.load_avg.fifteen) catch {};

    var core_buf: [16]u8 = undefined;
    for (this.cpu.cores, 0..) |core, i| {
        const core_pct: i64 = @intFromFloat(@round(core.usage));
        const key = mem.print(&core_buf, "core{d}", .{i}) catch continue;
        this.replacer.addKeyAny(key, core_pct) catch {};
    }

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
        const tt = mem.print(&tt_buf, "CPU Usage: {d:.1}%\nLoad: {d:.2} {d:.2} {d:.2}\nCores: {d}", .{
            usage_pct,
            this.cpu.load_avg.one,
            this.cpu.load_avg.five,
            this.cpu.load_avg.fifteen,
            this.cpu.cores.len,
        }) catch "CPU";
        this.base.setTooltip(tt);
    }

    const is_warning = usage_pct >= this.warning_threshold and usage_pct < this.critical_threshold;
    const is_critical = usage_pct >= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(usage_pct, false);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *CpuModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    _ = btn_num;
    const this: *CpuModule = @ptrCast(@alignCast(user_data orelse return false));
    this.toggleCpuPopover();
    return true;
}

pub fn toggleCpuPopover(this: *CpuModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 6);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "cpu-popover");

        const header = gtk.gtk_label_new("Processor (CPU)");
        if (header) |h| {
            gtk.gtk_widget_add_css_class(h, "title");
            gtk.gtk_box_append(@ptrCast(b), h);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        const usage_fraction = std.math.clamp(this.cpu.avg / 100.0, 0.0, 1.0);
        var avg_buf: [64]u8 = undefined;
        const avg_str = mem.printSentinel(&avg_buf, "Usage: {d:.1}% ({d} Cores)", .{ this.cpu.avg, this.cpu.cores.len }, 0) catch "CPU";
        const avg_lbl = gtk.gtk_label_new(avg_str.ptr);
        if (avg_lbl) |al| gtk.gtk_box_append(@ptrCast(b), al);

        const pbar = gtk.gtk_progress_bar_new();
        if (pbar) |pb| {
            gtk.gtk_progress_bar_set_fraction(@ptrCast(pb), usage_fraction);
            gtk.gtk_box_append(@ptrCast(b), pb);
        }

        if (this.cpu.cores.len > 0) {
            const cores_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
            if (cores_box) |cb| {
                const max_show = @min(this.cpu.cores.len, 8);
                for (this.cpu.cores[0..max_show], 0..) |core, idx| {
                    var core_buf: [64]u8 = undefined;
                    const core_str = mem.printSentinel(&core_buf, "Core {d}: {d:.1}% ・ {d:.2} GHz", .{ idx, core.usage, core.frequency.current.value.raw }, 0) catch "";
                    if (core_str.len > 0) {
                        const core_lbl = gtk.gtk_label_new(core_str.ptr);
                        if (core_lbl) |cl| gtk.gtk_box_append(@ptrCast(cb), cl);
                    }
                }
                gtk.gtk_box_append(@ptrCast(b), cb);
            }
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}
