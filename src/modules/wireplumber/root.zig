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

const WireplumberModule = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const Template = @import("utils").Template;
const sh = @import("utils").sh;
const bindings = @import("bindings");
const gdbus = bindings.gdbus;

const SinkClickContext = struct {
    id: u32,
    mod: *WireplumberModule,
};

base: *BaseModule,
allocator: Allocator,
io: Io,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
format: []const u8,
format_muted: []const u8,
format_icons: ArrayList([]const u8),
max_volume: u32,
scroll_step: f64,
is_source: bool = false,
session_bus: ?*gdbus.GDBusConnection = null,
timer_id: u32 = 0,
sync_timer_id: u32 = 0,
last_volume: ?u8 = null,
last_node_name: ?[]const u8 = null,
last_muted: bool = false,
popover: ?*gtk.GtkWidget = null,
sink_contexts: ArrayList(*SinkClickContext) = .empty,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*WireplumberModule {
    _ = bindings.pipewire.init();
    const this = try allocator.create(WireplumberModule);
    errdefer allocator.destroy(this);

    const is_source = settings.getBool("source") orelse (mem.find(u8, name, "source") != null or mem.find(u8, name, "mic") != null);

    this.base = try .initFromSettings(io, allocator, name, if (is_source) "wireplumber-source" else "wireplumber", settings);
    errdefer this.base.deinit();
    if (this.base.on_click == null) {
        this.base.on_click = try allocator.dupeSentinel(u8, "pavucontrol", 0);
    }

    this.allocator = allocator;
    this.io = io;
    this.is_source = is_source;
    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const def_fmt = if (is_source) " {volume}%" else "{icon}  {volume}%";
    const fmt_str = settings.getString("format") orelse def_fmt;
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.format = try allocator.dupe(u8, fmt_str);
    const def_muted = if (is_source) "" else "";
    this.format_muted = try allocator.dupe(u8, settings.getString("format-muted") orelse def_muted);
    this.max_volume = @intCast(settings.getInt("max-volume") orelse 150);
    this.scroll_step = @floatFromInt(settings.getInt("scroll-step") orelse 5);
    if (this.scroll_step <= 0) this.scroll_step = 5.0;

    this.format_icons = .empty;

    if (settings.value == .object and settings.value.object.get("format-icons") != null) {
        const icons_val = settings.value.object.get("format-icons").?;
        if (icons_val == .object) {
            if (icons_val.object.get("default")) |def_arr| {
                if (def_arr == .array) {
                    for (def_arr.array.items) |item| {
                        if (item == .string) {
                            try this.format_icons.append(this.allocator, try allocator.dupe(u8, item.string));
                        }
                    }
                }
            }
        } else if (icons_val == .array) {
            for (icons_val.array.items) |item| {
                if (item == .string) {
                    try this.format_icons.append(this.allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }

    if (this.format_icons.items.len == 0) {
        try this.format_icons.append(this.allocator, try allocator.dupe(u8, ""));
        try this.format_icons.append(this.allocator, try allocator.dupe(u8, ""));
        try this.format_icons.append(this.allocator, try allocator.dupe(u8, ""));
    }

    this.base.custom_scroll_handler = &onScroll;
    this.base.custom_scroll_data = this;

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.timer_id = 0;
    this.sync_timer_id = 0;
    this.session_bus = gdbus.getBus(.session);
    this.last_volume = null;
    this.last_node_name = null;
    this.last_muted = false;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(1, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *WireplumberModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    for (this.sink_contexts.items) |ctx| {
        this.allocator.destroy(ctx);
    }
    this.sink_contexts.deinit(this.allocator);

    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    if (this.sync_timer_id != 0) {
        _ = gtk.g_source_remove(this.sync_timer_id);
        this.sync_timer_id = 0;
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    for (this.format_icons.items) |ic| {
        this.allocator.free(ic);
    }
    this.format_icons.deinit(this.allocator);
    this.allocator.free(this.format);
    this.allocator.free(this.format_muted);
    if (this.last_node_name) |nn| this.allocator.free(nn);
    if (this.session_bus) |b| gdbus.g_object_unref(b);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn renderVolume(this: *WireplumberModule, vol: u8, muted: bool, node_name: []const u8) void {
    if (muted) {
        this.base.setText(this.format_muted);
        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "{s}\nVolume: {d}% [MUTED]", .{
            node_name,
            vol,
        }) catch "Muted";
        this.base.setTooltip(tt);
        this.base.addCssClass("muted");
        return;
    }

    this.base.removeCssClass("muted");

    const icon_str = this.getIconForVolume(vol);

    this.replacer.clear();
    this.replacer.addKey("icon", icon_str) catch {};
    this.replacer.addKeyAny("volume", @as(i64, vol)) catch {};
    this.replacer.addKey("node_name", node_name) catch {};

    var render_buf: [256]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch this.format;
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [512]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "{s}\nVolume: {d}%", .{
            node_name,
            vol,
        }) catch "Volume";
        this.base.setTooltip(tt);
    }
}

pub fn update(this: *WireplumberModule) void {
    var pw: sysinfo.pipewire = .init(this.io, this.allocator);
    const info = if (this.is_source)
        pw.getSourceAudioInfo() catch {
            this.base.setText("Mic N/A");
            this.base.setTooltip("PipeWire source not responding");
            return;
        }
    else
        pw.getAudioInfo() catch {
            this.base.setText("Audio N/A");
            this.base.setTooltip("PipeWire audio service not responding");
            return;
        };
    var mutable_info = info;
    defer mutable_info.deinit(this.allocator);

    this.last_volume = mutable_info.volume;
    this.last_muted = mutable_info.muted;
    if (this.last_node_name) |old_nn| this.allocator.free(old_nn);
    this.last_node_name = this.allocator.dupe(u8, mutable_info.node_name) catch null;

    this.renderVolume(mutable_info.volume, mutable_info.muted, mutable_info.node_name);
}

pub fn toggleMute(this: *WireplumberModule) void {
    const new_muted = !this.last_muted;
    this.last_muted = new_muted;

    const vol = this.last_volume orelse 50;
    const node_name = this.last_node_name orelse (if (this.is_source) "Default Audio Input" else "Default Audio Output");
    this.renderVolume(vol, new_muted, node_name);

    const target: [:0]const u8 = if (this.is_source) "@DEFAULT_AUDIO_SOURCE@" else "@DEFAULT_AUDIO_SINK@";
    var buf: [64]u8 = undefined;
    const printed = mem.printSentinel(&buf, "wpctl set-mute {s} {s}", .{ target, if (new_muted) "1" else "0" }, 0) catch return;
    _ = gtk.g_spawn_command_line_async(@ptrCast(printed.ptr), null);

    this.notifyPlasmaOsd(if (new_muted) 0 else vol);

    if (this.sync_timer_id != 0) {
        _ = gtk.g_source_remove(this.sync_timer_id);
    }
    this.sync_timer_id = gtk.g_timeout_add(150, @ptrCast(&onSyncTimeout), this);
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    const this: *WireplumberModule = @ptrCast(@alignCast(user_data orelse return false));
    if (btn_num == 2 and this.base.on_click_middle == null) {
        this.toggleMute();
        return true;
    }
    if (btn_num == 3 and this.base.on_click_right == null) {
        this.toggleSinkPopover();
        return true;
    }
    return false;
}

pub fn toggleSinkPopover(this: *WireplumberModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    for (this.sink_contexts.items) |ctx| {
        this.allocator.destroy(ctx);
    }
    this.sink_contexts.clearRetainingCapacity();

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 4);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "sink-switcher-popover");

        const header = gtk.gtk_label_new("Audio Output Devices");
        if (header) |h| {
            gtk.gtk_widget_add_css_class(h, "title");
            gtk.gtk_box_append(@ptrCast(b), h);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        const status_out = sh.runAlloc(this.base.io, this.allocator, "wpctl status 2>/dev/null") catch null;
        defer if (status_out) |so| this.allocator.free(so);

        if (status_out) |so| {
            var in_sinks = false;
            var line_it = mem.splitScalar(u8, so, '\n');
            while (line_it.next()) |raw_line| {
                const line = mem.trim(u8, raw_line, " \r\t");
                if (mem.find(u8, line, "Sinks:") != null) {
                    in_sinks = true;
                    continue;
                }
                if (in_sinks) {
                    if (mem.startsWith(u8, line, "├─") or mem.startsWith(u8, line, "└─") or mem.endsWith(u8, line, ":")) {
                        if (mem.find(u8, line, "Sinks:") == null) break;
                    }

                    const is_active = mem.find(u8, line, "*") != null;
                    var cursor: usize = 0;
                    while (cursor < line.len and (line[cursor] == '*' or line[cursor] == ' ' or line[cursor] == '.')) : (cursor += 1) {}
                    const after_star = line[cursor..];

                    if (mem.find(u8, after_star, ".")) |dot_idx| {
                        const id_part = mem.trim(u8, after_star[0..dot_idx], " ");
                        if (fmt.parseInt(u32, id_part, 10)) |sink_id| {
                            var name_part = mem.trim(u8, after_star[dot_idx + 1 ..], " ");
                            if (mem.find(u8, name_part, "[")) |bracket_idx| {
                                name_part = mem.trim(u8, name_part[0..bracket_idx], " ");
                            }

                            var btn_label_buf: [256]u8 = undefined;
                            const btn_label = mem.printSentinel(&btn_label_buf, "{s} {s}", .{ if (is_active) "✓ " else "  ", name_part }, 0) catch continue;

                            const item_btn = gtk.gtk_button_new_with_label(btn_label.ptr);
                            if (item_btn) |ib| {
                                if (is_active) gtk.gtk_widget_add_css_class(ib, "active");

                                const ctx = this.allocator.create(SinkClickContext) catch continue;
                                ctx.* = .{ .id = sink_id, .mod = this };
                                this.sink_contexts.append(this.allocator, ctx) catch {
                                    this.allocator.destroy(ctx);
                                    continue;
                                };

                                _ = gtk.g_signal_connect_data(ib, "clicked", @ptrCast(&onSinkSelected), ctx, null, 0);
                                gtk.gtk_box_append(@ptrCast(b), ib);
                            }
                        } else |_| {}
                    }
                }
            }
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onSinkSelected(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const ctx: *SinkClickContext = @ptrCast(@alignCast(user_data orelse return));
    var cmd_buf: [64]u8 = undefined;
    const cmd = mem.printSentinel(&cmd_buf, "wpctl set-default {d}", .{ctx.id}, 0) catch return;
    _ = gtk.g_spawn_command_line_async(@ptrCast(cmd.ptr), null);

    if (ctx.mod.popover) |pop| {
        gtk.gtk_popover_popdown(@ptrCast(pop));
    }
    ctx.mod.update();
}

fn getIconForVolume(this: *WireplumberModule, vol: u8) []const u8 {
    if (this.format_icons.items.len == 0) return if (this.is_source) "" else "";
    if (this.format_icons.items.len == 1) return this.format_icons.items[0];

    const idx = (@as(usize, vol) * (this.format_icons.items.len - 1)) / 100;
    const safe_idx = @min(idx, this.format_icons.items.len - 1);
    return this.format_icons.items[safe_idx];
}

fn onSyncTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *WireplumberModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.sync_timer_id = 0;
    this.update();
    return 0;
}

pub fn adjustVolume(this: *WireplumberModule, step_percent: f64) void {
    const current_vol = this.last_volume orelse 50;
    const step_i32: i32 = @intFromFloat(step_percent);
    const new_vol_i32 = @as(i32, current_vol) + step_i32;
    const clamped_vol: u8 = @intCast(std.math.clamp(new_vol_i32, 0, @as(i32, @intCast(this.max_volume))));
    this.last_volume = clamped_vol;

    const node_name = this.last_node_name orelse (if (this.is_source) "Default Audio Input" else "Default Audio Output");
    this.renderVolume(clamped_vol, false, node_name);

    const target: [:0]const u8 = if (this.is_source) "@DEFAULT_AUDIO_SOURCE@" else "@DEFAULT_AUDIO_SINK@";
    const max_limit = @as(f64, @floatFromInt(this.max_volume)) / 100.0;
    const vol_ratio = @as(f64, @floatFromInt(clamped_vol)) / 100.0;

    var buf: [128]u8 = undefined;
    const printed = mem.printSentinel(&buf, "wpctl set-volume -l {d:.2} {s} {d:.2}", .{ max_limit, target, vol_ratio }, 0) catch return;
    _ = gtk.g_spawn_command_line_async(@ptrCast(printed.ptr), null);

    this.notifyPlasmaOsd(clamped_vol);

    if (this.sync_timer_id != 0) {
        _ = gtk.g_source_remove(this.sync_timer_id);
    }
    this.sync_timer_id = gtk.g_timeout_add(150, @ptrCast(&onSyncTimeout), this);
}

fn notifyPlasmaOsd(this: *WireplumberModule, vol: u8) void {
    const bus = this.session_bus orelse return;
    var arg_buf: [32]u8 = undefined;
    const arg_z = mem.printSentinel(&arg_buf, "({d})", .{vol}, 0) catch return;
    const params = gdbus.g_variant_new_parsed(arg_z) orelse return;
    const method: [:0]const u8 = if (this.is_source) "microphoneVolumeChanged" else "volumeChanged";

    gdbus.callMethodFireAndForget(
        bus,
        "org.kde.plasmashell",
        "/org/kde/osdService",
        "org.kde.osdService",
        method,
        params,
    );
}

fn onScroll(user_data: ?*anyopaque, dy: f64) void {
    const this: *WireplumberModule = @ptrCast(@alignCast(user_data orelse return));
    if (dy < 0) {
        this.adjustVolume(this.scroll_step);
    } else if (dy > 0) {
        this.adjustVolume(-this.scroll_step);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *WireplumberModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
