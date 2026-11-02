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
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

pub const BluetoothModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    format_connected: []const u8,
    format_connected_battery: []const u8,
    format_disabled: []const u8,
    timer_id: u32 = 0,
    conn: ?*gtk.GDBusConnection = null,
    sub_props: c_uint = 0,
    sub_interfaces: c_uint = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*BluetoothModule {
        const self = try allocator.create(BluetoothModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click") orelse "blueman-manager";
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "bluetooth", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.allocator = allocator;
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "");
        self.format_connected = try allocator.dupe(u8, settings.getString("format-connected") orelse " {device_alias}");
        self.format_connected_battery = try allocator.dupe(u8, settings.getString("format-connected-battery") orelse " {device_alias} ・ {device_battery_percentage}%");
        self.format_disabled = try allocator.dupe(u8, settings.getString("format-disabled") orelse "");

        var err: ?*anyopaque = null;
        self.conn = gtk.g_bus_get_sync(1, null, &err);
        if (self.conn) |c| {
            self.sub_props = gtk.g_dbus_connection_signal_subscribe(c, "org.bluez", "org.freedesktop.DBus.Properties", "PropertiesChanged", null, null, 0, @ptrCast(&onBluezSignal), self, null);
            self.sub_interfaces = gtk.g_dbus_connection_signal_subscribe(c, "org.bluez", "org.freedesktop.DBus.ObjectManager", "InterfacesAdded", null, null, 0, @ptrCast(&onBluezSignal), self, null);
        }

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(3, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *BluetoothModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }

        if (self.conn) |c| {
            if (self.sub_props != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sub_props);
            if (self.sub_interfaces != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sub_interfaces);
            gtk.g_object_unref(c);
            self.conn = null;
        }

        self.allocator.free(self.format);
        self.allocator.free(self.format_connected);
        self.allocator.free(self.format_connected_battery);
        self.allocator.free(self.format_disabled);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *BluetoothModule) void {
        const c = self.conn orelse return;

        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_connection_call_sync(c, "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", null, null, 0, 1000, null, &err);
        if (res == null) {
            if (err) |e| gtk.g_error_free(e);
            self.renderDisabled();
            return;
        }
        defer gtk.g_variant_unref(res);

        const outer = gtk.g_variant_get_child_value(res, 0);
        if (outer == null) return;
        defer gtk.g_variant_unref(outer);

        var adapter_powered = false;
        var connected_alias: ?[]const u8 = null;
        var connected_address: ?[]const u8 = null;
        var connected_battery: ?u8 = null;
        var num_connected: usize = 0;

        const obj_iter = gtk.g_variant_iter_new(outer);
        if (obj_iter) |oit| {
            defer gtk.g_variant_iter_free(oit);
            while (gtk.g_variant_iter_next_value(oit)) |obj_entry| {
                defer gtk.g_variant_unref(obj_entry);
                const ifaces_v = gtk.g_variant_get_child_value(obj_entry, 1);
                defer if (ifaces_v) |iv| gtk.g_variant_unref(iv);
                if (ifaces_v == null) continue;

                const iface_iter = gtk.g_variant_iter_new(ifaces_v);
                if (iface_iter) |iit| {
                    defer gtk.g_variant_iter_free(iit);
                    while (gtk.g_variant_iter_next_value(iit)) |iface_entry| {
                        defer gtk.g_variant_unref(iface_entry);
                        const iface_name_v = gtk.g_variant_get_child_value(iface_entry, 0);
                        const props_v = gtk.g_variant_get_child_value(iface_entry, 1);
                        defer if (iface_name_v) |inv| gtk.g_variant_unref(inv);
                        defer if (props_v) |pv| gtk.g_variant_unref(pv);
                        if (iface_name_v == null or props_v == null) continue;

                        const iface_name_z = gtk.g_variant_get_string(iface_name_v, null) orelse continue;
                        const iface_name = mem.span(iface_name_z);

                        if (mem.eql(u8, iface_name, "org.bluez.Adapter1")) {
                            adapter_powered = true;
                        } else if (mem.eql(u8, iface_name, "org.bluez.Device1")) {
                            var is_conn = false;
                            var alias: []const u8 = "Unknown";
                            var addr: []const u8 = "";

                            const p_iter = gtk.g_variant_iter_new(props_v);
                            if (p_iter) |pit| {
                                defer gtk.g_variant_iter_free(pit);
                                while (gtk.g_variant_iter_next_value(pit)) |p_entry| {
                                    defer gtk.g_variant_unref(p_entry);
                                    const pk_v = gtk.g_variant_get_child_value(p_entry, 0);
                                    const pv_v = gtk.g_variant_get_child_value(p_entry, 1);
                                    defer if (pk_v) |pkv| gtk.g_variant_unref(pkv);
                                    defer if (pv_v) |pvv| gtk.g_variant_unref(pvv);
                                    if (pk_v == null or pv_v == null) continue;

                                    const pk_z = gtk.g_variant_get_string(pk_v, null) orelse continue;
                                    const pk = mem.span(pk_z);

                                    const pinner_v = gtk.g_variant_get_child_value(pv_v, 0);
                                    defer if (pinner_v) |pinv| gtk.g_variant_unref(pinv);
                                    if (pinner_v == null) continue;

                                    if (mem.eql(u8, pk, "Connected")) {
                                        if (gtk.g_variant_get_boolean(pinner_v) != 0) is_conn = true;
                                    } else if (mem.eql(u8, pk, "Alias") or mem.eql(u8, pk, "Name")) {
                                        if (gtk.g_variant_get_string(pinner_v, null)) |asz| alias = mem.span(asz);
                                    } else if (mem.eql(u8, pk, "Address")) {
                                        if (gtk.g_variant_get_string(pinner_v, null)) |asz| addr = mem.span(asz);
                                    }
                                }
                            }

                            if (is_conn) {
                                num_connected += 1;
                                if (connected_alias == null) {
                                    connected_alias = self.allocator.dupe(u8, alias) catch null;
                                    connected_address = self.allocator.dupe(u8, addr) catch null;
                                }
                            }
                        } else if (mem.eql(u8, iface_name, "org.bluez.Battery1")) {
                            const p_iter = gtk.g_variant_iter_new(props_v);
                            if (p_iter) |pit| {
                                defer gtk.g_variant_iter_free(pit);
                                while (gtk.g_variant_iter_next_value(pit)) |p_entry| {
                                    defer gtk.g_variant_unref(p_entry);
                                    const pk_v = gtk.g_variant_get_child_value(p_entry, 0);
                                    const pv_v = gtk.g_variant_get_child_value(p_entry, 1);
                                    defer if (pk_v) |pkv| gtk.g_variant_unref(pkv);
                                    defer if (pv_v) |pvv| gtk.g_variant_unref(pvv);
                                    if (pk_v == null or pv_v == null) continue;

                                    const pk_z = gtk.g_variant_get_string(pk_v, null) orelse continue;
                                    if (mem.eql(u8, mem.span(pk_z), "Percentage")) {
                                        const pinner_v = gtk.g_variant_get_child_value(pv_v, 0);
                                        defer if (pinner_v) |pinv| gtk.g_variant_unref(pinv);
                                        if (pinner_v) |pinv| {
                                            if (gtk.g_variant_is_of_type(pinv, "y") != 0) {
                                                connected_battery = gtk.g_variant_get_byte(pinv);
                                            } else if (gtk.g_variant_is_of_type(pinv, "u") != 0) {
                                                const pct = gtk.g_variant_get_uint32(pinv);
                                                connected_battery = @intCast(@min(pct, 100));
                                            } else if (gtk.g_variant_is_of_type(pinv, "i") != 0) {
                                                const pct = gtk.g_variant_get_int32(pinv);
                                                if (pct >= 0) connected_battery = @intCast(@min(pct, 100));
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        defer if (connected_alias) |a| self.allocator.free(a);
        defer if (connected_address) |a| self.allocator.free(a);

        if (!adapter_powered) {
            self.renderDisabled();
            return;
        }

        if (num_connected > 0) {
            self.base.addCssClass("connected");
            self.base.removeCssClass("disabled");

            var replacer: Replacer = .init(self.allocator);
            defer replacer.deinit();

            const dev_alias = connected_alias orelse "Bluetooth Device";
            const dev_addr = connected_address orelse "";

            replacer.addKey("device_alias", dev_alias) catch {};
            replacer.addKey("device_address", dev_addr) catch {};
            replacer.addKeyAny("num_connections", @as(i64, @intCast(num_connected))) catch {};
            replacer.addKey("status", "connected") catch {};

            var tmpl = self.format_connected;
            if (connected_battery) |bat| {
                replacer.addKeyAny("device_battery_percentage", @as(i64, bat)) catch {};
                if (self.format_connected_battery.len > 0) tmpl = self.format_connected_battery;
            }

            const rendered = replacer.render(tmpl) catch tmpl;
            defer if (rendered.ptr != tmpl.ptr) self.allocator.free(rendered);

            self.base.setText(rendered);

            var tt_buf: [256]u8 = undefined;
            const tt = if (connected_battery) |bat|
                mem.print(&tt_buf, "Device: {s} [{s}]\nBattery: {d}%", .{ dev_alias, dev_addr, bat }) catch "Bluetooth"
            else
                mem.print(&tt_buf, "Device: {s} [{s}]", .{ dev_alias, dev_addr }) catch "Bluetooth";
            self.base.setTooltip(tt);
        } else {
            self.base.removeCssClass("connected");
            self.base.removeCssClass("disabled");

            if (self.format.len > 0) {
                self.base.setText(self.format);
            } else {
                self.base.setText("");
            }

            self.base.setTooltip("Bluetooth: Enabled (No devices connected)");
        }
    }

    fn renderDisabled(self: *BluetoothModule) void {
        self.base.removeCssClass("connected");
        self.base.addCssClass("disabled");
        if (self.format_disabled.len > 0) {
            self.base.setText(self.format_disabled);
        } else {
            self.base.setText("");
        }

        self.base.setTooltip("Bluetooth: Disabled or Adapter not found");
    }
};

fn onBluezSignal(connection: ?*gtk.GDBusConnection, sender_name: ?[*:0]const u8, object_path: ?[*:0]const u8, interface_name: ?[*:0]const u8, signal_name: ?[*:0]const u8, parameters: ?*gtk.GVariant, user_data: gtk.gpointer) callconv(.c) void {
    _ = connection;
    _ = sender_name;
    _ = object_path;
    _ = interface_name;
    _ = signal_name;
    _ = parameters;
    const self: *BluetoothModule = @ptrCast(@alignCast(user_data orelse return));
    self.update();
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *BluetoothModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
