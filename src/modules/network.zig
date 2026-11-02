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

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

pub const NetworkModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    io: Io,
    format: []const u8,
    format_disconnected: []const u8,
    format_wifi: ?[]const u8 = null,
    format_ethernet: ?[]const u8 = null,
    tooltip_format: []const u8,
    tooltip_format_wifi: []const u8,
    max_length: usize,
    min_length: usize,
    interval_sec: u32,
    timer_id: u32 = 0,

    icon_ethernet: []const u8,
    icon_wifi: []const u8,
    icon_linked: []const u8,
    icon_disconnected: []const u8,

    last_stats: ?sysinfo.network.NetworkStats = null,

    pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*NetworkModule {
        const self = try allocator.create(NetworkModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "network", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.allocator = allocator;
        self.io = io;
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{icon}  {bandwidthTotalBytes}");
        self.format_disconnected = try allocator.dupe(u8, settings.getString("format-disconnected") orelse "󰤮 Disconnected");
        self.format_wifi = if (settings.getString("format-wifi")) |f| try allocator.dupe(u8, f) else null;
        self.format_ethernet = if (settings.getString("format-ethernet")) |f| try allocator.dupe(u8, f) else null;

        self.tooltip_format = try allocator.dupe(u8, settings.getString("tooltip-format") orelse "Gateway ・ {gwaddr}\nIP ・ {ipaddr}\nIF ・ {ifname}\n  {bandwidthDownBytes} ・   {bandwidthUpBytes}");
        self.tooltip_format_wifi = try allocator.dupe(u8, settings.getString("tooltip-format-wifi") orelse "SSID ・ {essid}\nGateway ・ {gwaddr}\nIP ・ {ipaddr}\nIF ・ {ifname}\nFrequency ・ {frequency}GHz\nStrength ・ {signalStrength}% ({signaldBm}dBm)\n  {bandwidthDownBytes} ・   {bandwidthUpBytes}");

        self.max_length = @intCast(settings.getInt("max-length") orelse 20);
        self.min_length = @intCast(settings.getInt("min-length") orelse 0);
        self.interval_sec = @intCast(settings.getInt("interval") orelse 1);

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

        self.icon_ethernet = try allocator.dupe(u8, eth_ic);
        self.icon_wifi = try allocator.dupe(u8, wifi_ic);
        self.icon_linked = try allocator.dupe(u8, linked_ic);
        self.icon_disconnected = try allocator.dupe(u8, disconn_ic);
        self.last_stats = null;

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *NetworkModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.allocator.free(self.format_disconnected);
        if (self.format_wifi) |f| self.allocator.free(f);
        if (self.format_ethernet) |f| self.allocator.free(f);
        self.allocator.free(self.tooltip_format);
        self.allocator.free(self.tooltip_format_wifi);
        self.allocator.free(self.icon_ethernet);
        self.allocator.free(self.icon_wifi);
        self.allocator.free(self.icon_linked);
        self.allocator.free(self.icon_disconnected);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *NetworkModule) void {
        const route_opt: ?sysinfo.network.RouteInfo = sysinfo.network.getDefaultRoute(self.io, self.allocator) catch null;
        if (route_opt == null) {
            self.renderDisconnected();
            return;
        }

        const route = route_opt.?;
        defer {
            self.allocator.free(route.interface);
            self.allocator.free(route.gateway);
        }

        const ifname = route.interface;
        const gwaddr = route.gateway;

        const local_ip: ?[]const u8 = sysinfo.network.getLocalIP(self.allocator, ifname) catch null;
        defer if (local_ip) |ip| self.allocator.free(ip);
        const ip_str = if (local_ip) |ip| ip else "127.0.0.1";

        var wifi_info = sysinfo.network.getWifiInfo(self.io, self.allocator, ifname);
        defer wifi_info.deinit(self.allocator);

        const now = @divTrunc(gtk.g_get_real_time(), 1_000_000);
        var down_speed: f64 = 0.0;
        var up_speed: f64 = 0.0;
        var total_speed: f64 = 0.0;

        const current_stats = sysinfo.network.getNetworkStats(self.io, ifname, now) catch null;
        if (current_stats) |cur| {
            if (self.last_stats) |prev| {
                const rates = sysinfo.network.NetworkStats.calculateRates(prev, cur);
                down_speed = rates.download;
                up_speed = rates.upload;
                total_speed = rates.total;
            }
            self.last_stats = cur;
        }

        var total_str_buf: [32]u8 = undefined;
        const total_str = formatBytesCustom(&total_str_buf, total_speed);

        var down_str_buf: [32]u8 = undefined;
        const down_str = formatBytesCustom(&down_str_buf, down_speed);

        var up_str_buf: [32]u8 = undefined;
        const up_str = formatBytesCustom(&up_str_buf, up_speed);

        const is_wifi = wifi_info.is_wireless or mem.startsWith(u8, ifname, "wl");
        const icon_str = if (is_wifi) self.icon_wifi else self.icon_ethernet;

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", icon_str) catch {};
        replacer.addKey("ifname", ifname) catch {};
        replacer.addKey("ipaddr", ip_str) catch {};
        replacer.addKey("gwaddr", gwaddr) catch {};
        replacer.addKey("bandwidthTotalBytes", total_str) catch {};
        replacer.addKey("bandwidthDownBytes", down_str) catch {};
        replacer.addKey("bandwidthUpBytes", up_str) catch {};

        if (wifi_info.ssid) |ssid| {
            replacer.addKey("essid", ssid) catch {};
        } else {
            replacer.addKey("essid", "N/A") catch {};
        }
        replacer.addKeyAny("signalStrength", @as(i64, wifi_info.signal_strength)) catch {};
        if (wifi_info.signal_dbm) |dbm| {
            replacer.addKeyAny("signaldBm", @as(i64, dbm)) catch {};
        } else {
            replacer.addKey("signaldBm", "0") catch {};
        }
        replacer.addKey("frequency", "2.4/5") catch {};

        var tmpl = self.format;
        if (is_wifi and self.format_wifi != null) {
            tmpl = self.format_wifi.?;
        } else if (!is_wifi and self.format_ethernet != null) {
            tmpl = self.format_ethernet.?;
        }

        const rendered = replacer.render(tmpl) catch tmpl;
        defer if (rendered.ptr != tmpl.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);
        self.base.removeCssClass("disconnected");
        self.base.addCssClass("linked");

        const tt_tmpl = if (is_wifi) self.tooltip_format_wifi else self.tooltip_format;
        const tt_rendered = replacer.render(tt_tmpl) catch tt_tmpl;
        defer if (tt_rendered.ptr != tt_tmpl.ptr) self.allocator.free(tt_rendered);

        self.base.setTooltip(tt_rendered);
    }

    fn renderDisconnected(self: *NetworkModule) void {
        self.last_stats = null;
        self.base.removeCssClass("linked");
        self.base.addCssClass("disconnected");

        if (self.format_disconnected.len > 0) {
            self.base.setText(self.format_disconnected);
        } else {
            self.base.setText("");
        }
        self.base.setTooltip("Network: Disconnected");
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
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *NetworkModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
