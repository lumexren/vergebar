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

const MemoryModule = @This();

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
const process = utils.Process;

base: *BaseModule,
memory: sysinfo.Memory,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,
popover: ?*gtk.GtkWidget = null,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*MemoryModule {
    const this = try allocator.create(MemoryModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "memory", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {percentage}%");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.memory = .init(io);
    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", ""));
    this.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 75.0);
    this.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
    this.interval_sec = settings.getOr(u32, "interval", 2);

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *MemoryModule) void {
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
    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *MemoryModule) void {
    this.memory.update() catch return;

    const used_pct: f64 = if (this.memory.physical.total > 0)
        (@as(f64, @floatFromInt(this.memory.physical.used)) / @as(f64, @floatFromInt(this.memory.physical.total))) * 100.0
    else
        0.0;
    const used_pct_int: i64 = @intFromFloat(@round(used_pct));

    const used_gb = @as(f64, @floatFromInt(this.memory.physical.used)) / 1024.0 / 1024.0 / 1024.0;
    const total_gb = @as(f64, @floatFromInt(this.memory.physical.total)) / 1024.0 / 1024.0 / 1024.0;
    const avail_gb = @as(f64, @floatFromInt(this.memory.physical.available)) / 1024.0 / 1024.0 / 1024.0;

    this.replacer.clear();

    const swap_pct: f64 = if (this.memory.swap.total > 0)
        (@as(f64, @floatFromInt(this.memory.swap.used)) / @as(f64, @floatFromInt(this.memory.swap.total))) * 100.0
    else
        0.0;
    const swap_used_gb = @as(f64, @floatFromInt(this.memory.swap.used)) / 1024.0 / 1024.0 / 1024.0;
    const swap_total_gb = @as(f64, @floatFromInt(this.memory.swap.total)) / 1024.0 / 1024.0 / 1024.0;

    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKeyAny("percentage", used_pct_int) catch {};
    this.replacer.addKeyAny("used_percentage", used_pct_int) catch {};
    this.replacer.addKeyAny("used", used_gb) catch {};
    this.replacer.addKeyAny("total", total_gb) catch {};
    this.replacer.addKeyAny("available", avail_gb) catch {};
    this.replacer.addKeyAny("swap_percentage", @as(i64, @intFromFloat(@round(swap_pct)))) catch {};
    this.replacer.addKeyAny("swap_used", swap_used_gb) catch {};
    this.replacer.addKeyAny("swap_total", swap_total_gb) catch {};

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
        const tt = mem.print(&tt_buf, "RAM: {d:.2} GiB / {d:.2} GiB ({d:.1}%)\nAvailable: {d:.2} GiB\nSwap: {d:.1}%", .{
            used_gb,
            total_gb,
            used_pct,
            avail_gb,
            swap_pct,
        }) catch "Memory";
        this.base.setTooltip(tt);
    }

    const is_warning = used_pct >= this.warning_threshold and used_pct < this.critical_threshold;
    const is_critical = used_pct >= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(used_pct, false);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *MemoryModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    _ = btn_num;
    const this: *MemoryModule = @ptrCast(@alignCast(user_data orelse return false));
    this.toggleMemoryPopover();
    return true;
}

pub fn toggleMemoryPopover(this: *MemoryModule) void {
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
        gtk.gtk_widget_add_css_class(b, "memory-popover");

        const header = gtk.gtk_label_new("Memory & Processes");
        if (header) |h| {
            gtk.gtk_widget_add_css_class(h, "title");
            gtk.gtk_box_append(@ptrCast(b), h);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        const used_gb = @as(f64, @floatFromInt(this.memory.physical.used)) / 1024.0 / 1024.0 / 1024.0;
        const total_gb = @as(f64, @floatFromInt(this.memory.physical.total)) / 1024.0 / 1024.0 / 1024.0;
        const ram_fraction = if (this.memory.physical.total > 0)
            @as(f64, @floatFromInt(this.memory.physical.used)) / @as(f64, @floatFromInt(this.memory.physical.total))
        else
            0.0;

        var ram_buf: [64]u8 = undefined;
        const ram_lbl_str = mem.printSentinel(&ram_buf, "RAM: {d:.2} / {d:.2} GiB", .{ used_gb, total_gb }, 0) catch "RAM";
        const ram_lbl = gtk.gtk_label_new(ram_lbl_str.ptr);
        if (ram_lbl) |rl| gtk.gtk_box_append(@ptrCast(b), rl);

        const pbar = gtk.gtk_progress_bar_new();
        if (pbar) |pb| {
            gtk.gtk_progress_bar_set_fraction(@ptrCast(pb), ram_fraction);
            gtk.gtk_box_append(@ptrCast(b), pb);
        }

        const top_hdr = gtk.gtk_label_new("Top Memory Consumers");
        if (top_hdr) |th| {
            gtk.gtk_widget_add_css_class(th, "subtitle");
            gtk.gtk_box_append(@ptrCast(b), th);
        }

        const io = this.base.io;
        const alloc = this.base.allocator;
        if (process.getTopMemoryProcesses(io, alloc, 5)) |procs| {
            defer alloc.free(procs);
            for (procs) |p| {
                if (p.pid == 0) continue;
                const name = p.name[0..p.name_len];
                const mb = @as(f64, @floatFromInt(p.rss_bytes)) / 1024.0 / 1024.0;
                var row_buf: [128]u8 = undefined;
                if (mem.printSentinel(&row_buf, "{s} ({d}) - {d:.1} MB", .{ name, p.pid, mb }, 0)) |row_str| {
                    const row_lbl = gtk.gtk_label_new(row_str.ptr);
                    if (row_lbl) |rl| gtk.gtk_box_append(@ptrCast(b), rl);
                } else |_| {}
            }
        } else |_| {}

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}
