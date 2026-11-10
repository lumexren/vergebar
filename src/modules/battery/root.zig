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

const BatteryModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;
const sysinfo = @import("sysinfo");
const bindings = @import("bindings");
const gdbus = bindings.gdbus;

base: *BaseModule,
replacer: Replacer,
template: Template,
template_charging: ?Template = null,
template_discharging: ?Template = null,
template_full: ?Template = null,
template_plugged: ?Template = null,
template_tooltip: ?Template = null,
format_icons: ArrayList([]const u8),
battery_name: ?[]const u8 = null,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,
popover: ?*gtk.GtkWidget = null,
last_capacity: u8 = 100,
last_health: ?u8 = null,
last_power_w: ?f64 = null,
last_cycles: ?u32 = null,
last_status: []const u8 = "Full",

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*BatteryModule {
    const this = try allocator.create(BatteryModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "battery", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {percentage}%");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_charging = if (settings.getString("format-charging")) |s| Template.compile(allocator, s) catch null else null;
    this.template_discharging = if (settings.getString("format-discharging")) |s| Template.compile(allocator, s) catch null else null;
    this.template_full = if (settings.getString("format-full")) |s| Template.compile(allocator, s) catch null else null;
    this.template_plugged = if (settings.getString("format-plugged")) |s| Template.compile(allocator, s) catch null else null;

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.format_icons = .empty;
    if (settings.value == .object and settings.value.object.get("format-icons") != null) {
        const icons_val = settings.value.object.get("format-icons").?;
        if (icons_val == .object) {
            if (icons_val.object.get("default")) |def_arr| {
                if (def_arr == .array) {
                    for (def_arr.array.items) |item| {
                        if (item == .string) {
                            try this.format_icons.append(allocator, try allocator.dupe(u8, item.string));
                        }
                    }
                }
            }
        } else if (icons_val == .array) {
            for (icons_val.array.items) |item| {
                if (item == .string) {
                    try this.format_icons.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }

    if (this.format_icons.items.len == 0) {
        const single_icon = settings.getOr([]const u8, "icon", "");
        try this.format_icons.append(allocator, try allocator.dupe(u8, single_icon));
    }

    this.battery_name = if (settings.getString("battery")) |b| try allocator.dupe(u8, b) else null;
    this.warning_threshold = settings.getOr(f64, "warning-threshold", 20.0);
    this.critical_threshold = settings.getOr(f64, "critical-threshold", 10.0);
    this.interval_sec = settings.getOr(u32, "interval", 5);

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *BatteryModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    const alloc = this.base.allocator;
    if (this.timer_id != 0) _ = gtk.g_source_remove(this.timer_id);
    this.template.deinit();
    if (this.template_charging) |*tc| tc.deinit();
    if (this.template_discharging) |*td| td.deinit();
    if (this.template_full) |*tf| tf.deinit();
    if (this.template_plugged) |*tp| tp.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    for (this.format_icons.items) |ic| {
        alloc.free(ic);
    }
    this.format_icons.deinit(alloc);
    if (this.battery_name) |b| alloc.free(b);
    this.base.deinit();
    alloc.destroy(this);
}

fn getIconForCapacity(this: *BatteryModule, cap: u8) []const u8 {
    if (this.format_icons.items.len == 0) return "";
    if (this.format_icons.items.len == 1) return this.format_icons.items[0];

    const idx = (@as(usize, cap) * (this.format_icons.items.len - 1)) / 100;
    const safe_idx = @min(idx, this.format_icons.items.len - 1);
    return this.format_icons.items[safe_idx];
}

pub fn update(this: *BatteryModule) void {
    var capacity: u8 = 100;
    var status_str: []const u8 = "Full";
    var time_to_str: []const u8 = "";
    var power_str: []const u8 = "";
    var health_val: ?u8 = null;
    var cycles_val: ?u32 = null;

    var time_buf: [16]u8 = undefined;
    var pow_buf: [16]u8 = undefined;

    if (sysinfo.battery.readBatterySysfs(this.base.io, this.battery_name)) |stat| {
        capacity = stat.capacity;
        status_str = stat.statusSlice();
        if (stat.time_to_minutes) |ttm| {
            const hrs = ttm / 60;
            const mins = ttm % 60;
            time_to_str = mem.print(&time_buf, "{d:0>2}:{d:0>2}", .{ hrs, mins }) catch "";
        }
        if (stat.power_watts) |pw| {
            power_str = mem.print(&pow_buf, "{d:.1}W", .{pw}) catch "";
        }
        health_val = stat.health;
        cycles_val = stat.cycles;
    }

    const icon_str = this.getIconForCapacity(capacity);

    this.last_capacity = capacity;
    this.last_status = status_str;
    this.last_health = health_val;
    this.last_cycles = cycles_val;

    this.replacer.clear();

    this.replacer.addKey("icon", icon_str) catch {};
    this.replacer.addKeyAny("percentage", capacity) catch {};
    this.replacer.addKey("state", status_str) catch {};
    this.replacer.addKey("timeTo", time_to_str) catch {};
    this.replacer.addKey("power", power_str) catch {};
    if (health_val) |h| {
        this.replacer.addKeyAny("health", h) catch {};
    } else {
        this.replacer.addKey("health", "") catch {};
    }
    if (cycles_val) |c| {
        this.replacer.addKeyAny("cycles", c) catch {};
    } else {
        this.replacer.addKey("cycles", "") catch {};
    }

    var tmpl_to_render = &this.template;
    if (mem.find(u8, status_str, "Charging") != null or mem.eql(u8, status_str, "Charging")) {
        if (this.template_charging) |*tc| tmpl_to_render = tc;
    } else if (mem.find(u8, status_str, "Discharging") != null or mem.eql(u8, status_str, "Discharging")) {
        if (this.template_discharging) |*td| tmpl_to_render = td;
    } else if (mem.find(u8, status_str, "Full") != null or mem.eql(u8, status_str, "Full")) {
        if (this.template_full) |*tf| tmpl_to_render = tf;
    } else if (mem.find(u8, status_str, "Not charging") != null or mem.find(u8, status_str, "Plugged") != null) {
        if (this.template_plugged) |*tp| tmpl_to_render = tp;
    }

    var render_buf: [128]u8 = undefined;
    const rendered = tmpl_to_render.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "Battery: {s} ({d}%)", .{ status_str, capacity }) catch "Battery";
        this.base.setTooltip(tt);
    }

    const cap_pct: f64 = @floatFromInt(capacity);
    const is_warning = cap_pct <= this.warning_threshold and cap_pct > this.critical_threshold;
    const is_critical = cap_pct <= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(cap_pct, true);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *BatteryModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    _ = btn_num;
    const this: *BatteryModule = @ptrCast(@alignCast(user_data orelse return false));
    this.toggleBatteryPopover();
    return true;
}

pub fn toggleBatteryPopover(this: *BatteryModule) void {
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
        gtk.gtk_widget_add_css_class(b, "battery-popover");

        const header = gtk.gtk_label_new("Battery & Power");
        if (header) |h| {
            gtk.gtk_widget_add_css_class(h, "title");
            gtk.gtk_box_append(@ptrCast(b), h);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        var cap_buf: [64]u8 = undefined;
        const cap_str = mem.printSentinel(&cap_buf, "Charge: {d}% ({s})", .{ this.last_capacity, this.last_status }, 0) catch "Battery";
        const cap_lbl = gtk.gtk_label_new(cap_str.ptr);
        if (cap_lbl) |cl| gtk.gtk_box_append(@ptrCast(b), cl);

        const pbar = gtk.gtk_progress_bar_new();
        if (pbar) |pb| {
            gtk.gtk_progress_bar_set_fraction(@ptrCast(pb), @as(f64, @floatFromInt(this.last_capacity)) / 100.0);
            gtk.gtk_box_append(@ptrCast(b), pb);
        }

        if (this.last_health) |h| {
            var h_buf: [64]u8 = undefined;
            const cyc = this.last_cycles orelse 0;
            const h_str = mem.printSentinel(&h_buf, "Health: {d}% ・ Cycles: {d}", .{ h, cyc }, 0) catch "";
            if (h_str.len > 0) {
                const h_lbl = gtk.gtk_label_new(h_str.ptr);
                if (h_lbl) |hl| gtk.gtk_box_append(@ptrCast(b), hl);
            }
        }

        const prof_hdr = gtk.gtk_label_new("Power Profile");
        if (prof_hdr) |ph| {
            gtk.gtk_widget_add_css_class(ph, "subtitle");
            gtk.gtk_box_append(@ptrCast(b), ph);
        }

        const prof_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 4);
        if (prof_box) |pb| {
            const btn_saver = gtk.gtk_button_new_with_label("󰌪 Power Saver");
            if (btn_saver) |bs| {
                _ = gtk.g_signal_connect_data(bs, "clicked", @ptrCast(&onProfileSaverClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(pb), bs);
            }

            const btn_bal = gtk.gtk_button_new_with_label("󰾅 Balanced");
            if (btn_bal) |bb| {
                _ = gtk.g_signal_connect_data(bb, "clicked", @ptrCast(&onProfileBalancedClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(pb), bb);
            }

            const btn_perf = gtk.gtk_button_new_with_label("󰓅 Performance");
            if (btn_perf) |bp| {
                _ = gtk.g_signal_connect_data(bp, "clicked", @ptrCast(&onProfilePerfClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(pb), bp);
            }

            gtk.gtk_box_append(@ptrCast(b), pb);
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn setPowerProfile(profile: [:0]const u8) void {
    const bus = gdbus.getBus(.system);
    if (bus) |b| {
        defer gdbus.g_object_unref(b);
        var arg_buf: [128]u8 = undefined;
        const arg_z = mem.printSentinel(&arg_buf, "('org.freedesktop.UPower.PowerProfiles', 'ActiveProfile', <'{s}'>)", .{profile}, 0) catch return;
        if (gdbus.g_variant_new_parsed(arg_z)) |params| {
            gdbus.callMethodFireAndForget(
                b,
                "net.hadess.PowerProfiles",
                "/net/hadess/PowerProfiles",
                "org.freedesktop.DBus.Properties",
                "Set",
                params,
            );
        }
    }
}

fn onProfileSaverClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *BatteryModule = @ptrCast(@alignCast(user_data orelse return));
    setPowerProfile("power-saver");
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onProfileBalancedClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *BatteryModule = @ptrCast(@alignCast(user_data orelse return));
    setPowerProfile("balanced");
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onProfilePerfClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *BatteryModule = @ptrCast(@alignCast(user_data orelse return));
    setPowerProfile("performance");
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}
