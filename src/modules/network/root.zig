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

const NetworkModule = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;

base: *BaseModule,
allocator: Allocator,
io: Io,
replacer: Replacer,
template: Template,
format_disconnected: []const u8,
template_wifi: ?Template = null,
template_ethernet: ?Template = null,
template_tt: Template,
template_tt_wifi: Template,
max_length: usize,
min_length: usize,
interval_sec: u32,
timer_id: u32 = 0,

icon_ethernet: []const u8,
icon_wifi: []const u8,
icon_linked: []const u8,
icon_disconnected: []const u8,
current_ip: ?[:0]const u8 = null,
last_stats: ?sysinfo.network.NetworkStats = null,
popover: ?*gtk.GtkWidget = null,
last_gw: ?[]u8 = null,
last_ifname: ?[]u8 = null,
last_essid: ?[]u8 = null,
last_signal: u8 = 0,
last_freq: []const u8 = "2.4/5",

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*NetworkModule {
    const this = try allocator.create(NetworkModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "network", settings);
    errdefer this.base.deinit();
    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.allocator = allocator;
    this.io = io;
    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_raw = settings.getOr([]const u8, "format", "{icon}  {bandwidthTotalBytes}");
    this.template = try .compile(allocator, fmt_raw);
    errdefer this.template.deinit();

    this.format_disconnected = try allocator.dupe(u8, settings.getOr([]const u8, "format-disconnected", "󰤮 Disconnected"));
    this.template_wifi = if (settings.getString("format-wifi")) |f| try .compile(allocator, f) else null;
    this.template_ethernet = if (settings.getString("format-ethernet")) |f| try .compile(allocator, f) else null;

    const tt_raw = settings.getOr([]const u8, "tooltip-format", "Gateway ・ {gwaddr}\nIP ・ {ipaddr}\nIF ・ {ifname}\n  {bandwidthDownBytes} ・   {bandwidthUpBytes}");
    this.template_tt = try .compile(allocator, tt_raw);
    errdefer this.template_tt.deinit();

    const ttw_raw = settings.getOr([]const u8, "tooltip-format-wifi", "SSID ・ {essid}\nGateway ・ {gwaddr}\nIP ・ {ipaddr}\nIF ・ {ifname}\nFrequency ・ {frequency}GHz\nStrength ・ {signalStrength}% ({signaldBm}dBm)\n  {bandwidthDownBytes} ・   {bandwidthUpBytes}");
    this.template_tt_wifi = try .compile(allocator, ttw_raw);
    errdefer this.template_tt_wifi.deinit();

    this.max_length = settings.getOr(usize, "max-length", 20);
    this.min_length = settings.getOr(usize, "min-length", 0);
    this.interval_sec = settings.getOr(u32, "interval", 1);

    var eth_ic: []const u8 = "";
    var wifi_ic: []const u8 = "";
    var linked_ic: []const u8 = "";
    var disconn_ic: []const u8 = "󰤮";

    if (settings.value == .object and settings.value.object.get("format-icons") != null) {
        const icons_val = settings.value.object.get("format-icons").?;
        if (icons_val == .object) {
            if (icons_val.object.get("ethernet")) |v| if (v == .string) {
                eth_ic = v.string;
            };
            if (icons_val.object.get("wifi")) |v| if (v == .string) {
                wifi_ic = v.string;
            };
            if (icons_val.object.get("linked")) |v| if (v == .string) {
                linked_ic = v.string;
            };
            if (icons_val.object.get("disconnected")) |v| if (v == .string) {
                disconn_ic = v.string;
            };
        }
    }

    this.icon_ethernet = try allocator.dupe(u8, eth_ic);
    this.icon_wifi = try allocator.dupe(u8, wifi_ic);
    this.icon_linked = try allocator.dupe(u8, linked_ic);
    this.icon_disconnected = try allocator.dupe(u8, disconn_ic);
    this.last_stats = null;
    this.current_ip = null;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *NetworkModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template.deinit();
    if (this.template_wifi) |*tw| tw.deinit();
    if (this.template_ethernet) |*te| te.deinit();
    this.template_tt.deinit();
    this.template_tt_wifi.deinit();
    this.replacer.deinit();
    this.allocator.free(this.format_disconnected);
    this.allocator.free(this.icon_ethernet);
    this.allocator.free(this.icon_wifi);
    this.allocator.free(this.icon_linked);
    this.allocator.free(this.icon_disconnected);
    if (this.current_ip) |ip| this.allocator.free(ip);
    if (this.last_gw) |gw| this.allocator.free(gw);
    if (this.last_ifname) |ifn| this.allocator.free(ifn);
    if (this.last_essid) |ess| this.allocator.free(ess);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *NetworkModule) void {
    const route_opt: ?sysinfo.network.RouteInfo = sysinfo.network.getDefaultRoute(this.io, this.allocator) catch null;
    if (route_opt == null) {
        this.renderDisconnected();
        return;
    }

    const route = route_opt.?;
    defer {
        this.allocator.free(route.interface);
        this.allocator.free(route.gateway);
    }

    const ifname = route.interface;
    const gwaddr = route.gateway;

    const local_ip: ?[]const u8 = sysinfo.network.getLocalIP(this.allocator, ifname) catch null;
    defer if (local_ip) |ip| this.allocator.free(ip);
    const ip_str = if (local_ip) |ip| ip else "127.0.0.1";

    if (this.current_ip) |old_ip| this.allocator.free(old_ip);
    this.current_ip = this.allocator.dupeSentinel(u8, ip_str, 0) catch null;

    var wifi_info = sysinfo.network.getWifiInfo(this.io, this.allocator, ifname);
    defer wifi_info.deinit(this.allocator);

    if (this.last_gw) |gw| this.allocator.free(gw);
    this.last_gw = this.allocator.dupe(u8, gwaddr) catch null;

    if (this.last_ifname) |ifn| this.allocator.free(ifn);
    this.last_ifname = this.allocator.dupe(u8, ifname) catch null;

    if (this.last_essid) |ess| this.allocator.free(ess);
    if (wifi_info.ssid) |ssid| {
        this.last_essid = this.allocator.dupe(u8, ssid) catch null;
    } else {
        this.last_essid = null;
    }
    this.last_signal = wifi_info.signal_strength;

    const now = @divTrunc(gtk.g_get_real_time(), 1_000_000);
    var down_speed: f64 = 0.0;
    var up_speed: f64 = 0.0;
    var total_speed: f64 = 0.0;

    const current_stats = sysinfo.network.getNetworkStats(this.io, ifname, now) catch null;
    if (current_stats) |cur| {
        if (this.last_stats) |prev| {
            const rates = sysinfo.network.NetworkStats.calculateRates(prev, cur);
            down_speed = rates.download;
            up_speed = rates.upload;
            total_speed = rates.total;
        }
        this.last_stats = cur;
    }

    var total_str_buf: [32]u8 = undefined;
    const total_str = formatBytesCustom(&total_str_buf, total_speed);

    var down_str_buf: [32]u8 = undefined;
    const down_str = formatBytesCustom(&down_str_buf, down_speed);

    var up_str_buf: [32]u8 = undefined;
    const up_str = formatBytesCustom(&up_str_buf, up_speed);

    const is_wifi = wifi_info.is_wireless or mem.startsWith(u8, ifname, "wl");
    const icon_str = if (is_wifi) this.icon_wifi else this.icon_ethernet;

    this.replacer.clear();

    this.replacer.addKey("icon", icon_str) catch {};
    this.replacer.addKey("ifname", ifname) catch {};
    this.replacer.addKey("ipaddr", ip_str) catch {};
    this.replacer.addKey("gwaddr", gwaddr) catch {};
    this.replacer.addKey("bandwidthTotalBytes", total_str) catch {};
    this.replacer.addKey("bandwidthDownBytes", down_str) catch {};
    this.replacer.addKey("bandwidthUpBytes", up_str) catch {};

    if (wifi_info.ssid) |ssid| {
        this.replacer.addKey("essid", ssid) catch {};
        this.replacer.addKey("ssid", ssid) catch {};
    } else {
        this.replacer.addKey("essid", "N/A") catch {};
        this.replacer.addKey("ssid", "N/A") catch {};
    }
    this.replacer.addKeyAny("signalStrength", @as(i64, wifi_info.signal_strength)) catch {};
    this.replacer.addKeyAny("strength", @as(i64, wifi_info.signal_strength)) catch {};
    if (wifi_info.signal_dbm) |dbm| {
        this.replacer.addKeyAny("signaldBm", @as(i64, dbm)) catch {};
    } else {
        this.replacer.addKey("signaldBm", "0") catch {};
    }
    this.replacer.addKey("frequency", "2.4/5") catch {};

    var render_buf: [256]u8 = undefined;
    const active_tmpl = if (is_wifi and this.template_wifi != null)
        &this.template_wifi.?
    else if (!is_wifi and this.template_ethernet != null)
        &this.template_ethernet.?
    else
        &this.template;

    const rendered = active_tmpl.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);
    this.base.removeCssClass("disconnected");
    this.base.addCssClass("linked");

    var tt_buf: [512]u8 = undefined;
    const active_tt_tmpl = if (is_wifi) &this.template_tt_wifi else &this.template_tt;
    const tt_rendered = active_tt_tmpl.renderBuf(&this.replacer, &tt_buf) catch "";

    this.base.setTooltip(tt_rendered);
}

fn renderDisconnected(this: *NetworkModule) void {
    if (this.current_ip) |old_ip| {
        this.allocator.free(old_ip);
        this.current_ip = null;
    }
    this.last_stats = null;
    this.base.removeCssClass("linked");
    this.base.addCssClass("disconnected");

    if (this.format_disconnected.len > 0) {
        this.base.setText(this.format_disconnected);
    } else {
        this.base.setText("");
    }
    this.base.setTooltip("Network: Disconnected");
}

fn formatBytesCustom(buf: []u8, bytes_per_sec: f64) []const u8 {
    if (bytes_per_sec < 1024.0) {
        return mem.print(buf, "{d:.0}B/s", .{bytes_per_sec}) catch "0B/s";
    } else if (bytes_per_sec < 1024.0 * 1024.0) {
        return mem.print(buf, "{d:.1}KB/s", .{bytes_per_sec / 1024.0}) catch "0KB/s";
    } else if (bytes_per_sec < 1024.0 * 1024.0 * 1024.0) {
        return mem.print(buf, "{d:.1}MB/s", .{bytes_per_sec / (1024.0 * 1024.0)}) catch "0MB/s";
    } else {
        return mem.print(buf, "{d:.2}GB/s", .{bytes_per_sec / (1024.0 * 1024.0 * 1024.0)}) catch "0GB/s";
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *NetworkModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    const this: *NetworkModule = @ptrCast(@alignCast(user_data orelse return false));
    if (btn_num == 1) {
        if (this.base.on_click != null) return false;
        this.toggleNetworkPopover();
        return true;
    } else if (btn_num == 3 and this.base.on_click_right == null) {
        if (this.current_ip) |ip| {
            var buf: [128]u8 = undefined;
            const cmd = mem.print(&buf, "wl-copy {s}\x00", .{ip}) catch return false;
            _ = gtk.g_spawn_command_line_async(@ptrCast(cmd.ptr), null);
            return true;
        }
    }
    return false;
}

fn toggleNetworkPopover(this: *NetworkModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        }
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    this.popover = pop;

    gtk.gtk_widget_set_parent(pop, parent_btn);

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "network-popover");

        const title = gtk.gtk_label_new("Network Details");
        if (title) |t| {
            gtk.gtk_widget_add_css_class(t, "title");
            gtk.gtk_box_append(@ptrCast(b), t);
        }

        var ip_buf: [128]u8 = undefined;
        const ip_text = if (this.current_ip) |ip|
            mem.printSentinel(&ip_buf, "IP: {s}", .{ip}, 0) catch "IP: -"
        else
            "IP: Disconnected";
        const ip_lbl = gtk.gtk_label_new(ip_text.ptr);
        if (ip_lbl) |il| {
            gtk.gtk_box_append(@ptrCast(b), il);
        }

        var gw_buf: [128]u8 = undefined;
        const gw_text = if (this.last_gw) |gw|
            mem.printSentinel(&gw_buf, "Gateway: {s}", .{gw}, 0) catch "Gateway: -"
        else
            "Gateway: -";
        const gw_lbl = gtk.gtk_label_new(gw_text.ptr);
        if (gw_lbl) |gl| {
            gtk.gtk_box_append(@ptrCast(b), gl);
        }

        var if_buf: [128]u8 = undefined;
        const if_text = if (this.last_ifname) |ifn|
            mem.printSentinel(&if_buf, "Interface: {s}", .{ifn}, 0) catch "Interface: -"
        else
            "Interface: -";
        const if_lbl = gtk.gtk_label_new(if_text.ptr);
        if (if_lbl) |ifl| {
            gtk.gtk_box_append(@ptrCast(b), ifl);
        }

        if (this.last_essid) |essid| {
            var wifi_buf: [128]u8 = undefined;
            const wifi_text = mem.printSentinel(&wifi_buf, "Wi-Fi: {s} ({d}%)", .{ essid, this.last_signal }, 0) catch "Wi-Fi: -";
            const wifi_lbl = gtk.gtk_label_new(wifi_text.ptr);
            if (wifi_lbl) |wl| {
                gtk.gtk_box_append(@ptrCast(b), wl);
            }
        }

        const actions_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 6);
        if (actions_box) |ab| {
            const btn_copy = gtk.gtk_button_new_with_label("󰆏 Copy IP");
            if (btn_copy) |bc| {
                _ = gtk.g_signal_connect_data(bc, "clicked", @ptrCast(&onCopyIpClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(ab), bc);
            }

            const btn_editor = gtk.gtk_button_new_with_label("󰢻 Network Settings");
            if (btn_editor) |be| {
                _ = gtk.g_signal_connect_data(be, "clicked", @ptrCast(&onOpenEditorClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(ab), be);
            }

            gtk.gtk_box_append(@ptrCast(b), ab);
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onCopyIpClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *NetworkModule = @ptrCast(@alignCast(user_data orelse return));
    if (this.current_ip) |ip| {
        const display = gtk.gdk_display_get_default();
        if (display) |d| {
            const clip = gtk.gdk_display_get_clipboard(d);
            if (clip) |c| {
                gtk.gdk_clipboard_set_text(c, ip.ptr);
            }
        }
    }
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onOpenEditorClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *NetworkModule = @ptrCast(@alignCast(user_data orelse return));
    _ = gtk.g_spawn_command_line_async("nm-connection-editor", null);
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}
