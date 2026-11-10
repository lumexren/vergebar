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

const BluetoothModule = @This();

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

const BluetoothDeviceContext = struct {
    path: [:0]const u8,
    is_connected: bool,
    mod: *BluetoothModule,
};

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template_format: Template,
template_connected: Template,
template_connected_battery: Template,
template_disabled: Template,
template_tooltip: ?Template = null,
format: []const u8,
format_connected: []const u8,
format_connected_battery: []const u8,
format_disabled: []const u8,
timer_id: u32 = 0,
conn: ?*gtk.GDBusConnection = null,
sub_props: c_uint = 0,
sub_interfaces: c_uint = 0,
adapter_path: ?[:0]const u8 = null,
is_powered: bool = false,
popover: ?*gtk.GtkWidget = null,
device_contexts: ArrayList(*BluetoothDeviceContext) = .empty,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*BluetoothModule {
    const this = try allocator.create(BluetoothModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "bluetooth", settings);
    errdefer this.base.deinit();
    if (this.base.on_click == null) {
        this.base.on_click = try allocator.dupeSentinel(u8, "blueman-manager", 0);
    }

    this.allocator = allocator;
    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getString("format") orelse "";
    const fmt_conn = settings.getString("format-connected") orelse " {device_alias}";
    const fmt_conn_bat = settings.getString("format-connected-battery") orelse " {device_alias} ・ {device_battery_percentage}%";
    const fmt_dis = settings.getString("format-disabled") orelse "";

    this.template_format = try .compile(allocator, fmt_str);
    errdefer this.template_format.deinit();
    this.template_connected = try .compile(allocator, fmt_conn);
    errdefer this.template_connected.deinit();
    this.template_connected_battery = try .compile(allocator, fmt_conn_bat);
    errdefer this.template_connected_battery.deinit();
    this.template_disabled = try .compile(allocator, fmt_dis);
    errdefer this.template_disabled.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.format = try allocator.dupe(u8, fmt_str);
    this.format_connected = try allocator.dupe(u8, fmt_conn);
    this.format_connected_battery = try allocator.dupe(u8, fmt_conn_bat);
    this.format_disabled = try allocator.dupe(u8, fmt_dis);

    this.timer_id = 0;
    this.conn = null;
    this.sub_props = 0;
    this.sub_interfaces = 0;
    this.adapter_path = null;
    this.is_powered = false;

    var err: ?*anyopaque = null;
    this.conn = gtk.g_bus_get_sync(1, null, &err);
    if (this.conn) |c| {
        this.sub_props = gtk.g_dbus_connection_signal_subscribe(c, "org.bluez", "org.freedesktop.DBus.Properties", "PropertiesChanged", null, null, 0, @ptrCast(&onBluezSignal), this, null);
        this.sub_interfaces = gtk.g_dbus_connection_signal_subscribe(c, "org.bluez", "org.freedesktop.DBus.ObjectManager", "InterfacesAdded", null, null, 0, @ptrCast(&onBluezSignal), this, null);
    }

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(3, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *BluetoothModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    for (this.device_contexts.items) |ctx| {
        this.allocator.free(ctx.path);
        this.allocator.destroy(ctx);
    }
    this.device_contexts.deinit(this.allocator);

    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template_format.deinit();
    this.template_connected.deinit();
    this.template_connected_battery.deinit();
    this.template_disabled.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();

    if (this.conn) |c| {
        if (this.sub_props != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sub_props);
        if (this.sub_interfaces != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sub_interfaces);
        this.conn = null;
    }

    if (this.adapter_path) |ap| this.allocator.free(ap);
    this.allocator.free(this.format);
    this.allocator.free(this.format_connected);
    this.allocator.free(this.format_connected_battery);
    this.allocator.free(this.format_disabled);
    const alloc = this.allocator;
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *BluetoothModule) void {
    const c = this.conn orelse return;

    var err: ?*anyopaque = null;
    const res = gtk.g_dbus_connection_call_sync(c, "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", null, null, 0, 1000, null, &err);
    if (res == null) {
        if (err) |e| gtk.g_error_free(e);
        this.renderDisabled();
        return;
    }
    defer gtk.g_variant_unref(res);

    const outer = gtk.g_variant_get_child_value(res, 0);
    if (outer == null) return;
    defer gtk.g_variant_unref(outer);

    var adapter_powered = false;
    var adapter_alias: ?[]const u8 = null;
    var adapter_address: ?[]const u8 = null;
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
                        const path_v = gtk.g_variant_get_child_value(obj_entry, 0);
                        defer if (path_v) |pv| gtk.g_variant_unref(pv);
                        if (path_v) |pv| {
                            if (gtk.g_variant_get_string(pv, null)) |pz| {
                                if (this.adapter_path) |old_p| this.allocator.free(old_p);
                                this.adapter_path = this.allocator.dupeSentinel(u8, mem.span(pz), 0) catch null;
                            }
                        }

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
                                if (mem.eql(u8, pk, "Powered")) {
                                    const val_v = gtk.g_variant_get_variant(pv_v);
                                    defer if (val_v) |vv| gtk.g_variant_unref(vv);
                                    if (val_v) |vv| {
                                        adapter_powered = gtk.g_variant_get_boolean(vv) != 0;
                                    }
                                } else if (mem.eql(u8, pk, "Alias") or mem.eql(u8, pk, "Name")) {
                                    const val_v = gtk.g_variant_get_variant(pv_v);
                                    defer if (val_v) |vv| gtk.g_variant_unref(vv);
                                    if (val_v) |vv| {
                                        if (gtk.g_variant_get_string(vv, null)) |asz| {
                                            if (adapter_alias == null) adapter_alias = this.allocator.dupe(u8, mem.span(asz)) catch null;
                                        }
                                    }
                                } else if (mem.eql(u8, pk, "Address")) {
                                    const val_v = gtk.g_variant_get_variant(pv_v);
                                    defer if (val_v) |vv| gtk.g_variant_unref(vv);
                                    if (val_v) |vv| {
                                        if (gtk.g_variant_get_string(vv, null)) |asz| {
                                            if (adapter_address == null) adapter_address = this.allocator.dupe(u8, mem.span(asz)) catch null;
                                        }
                                    }
                                }
                            }
                        }
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
                                connected_alias = this.allocator.dupe(u8, alias) catch null;
                                connected_address = this.allocator.dupe(u8, addr) catch null;
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
                                        const ts = mem.span(gtk.g_variant_get_type_string(pinv));
                                        if (mem.eql(u8, ts, "y")) {
                                            connected_battery = gtk.g_variant_get_byte(pinv);
                                        } else if (mem.eql(u8, ts, "u")) {
                                            const pct = gtk.g_variant_get_uint32(pinv);
                                            connected_battery = @intCast(@min(pct, 100));
                                        } else if (mem.eql(u8, ts, "i")) {
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

    defer if (adapter_alias) |a| this.allocator.free(a);
    defer if (adapter_address) |a| this.allocator.free(a);
    defer if (connected_alias) |a| this.allocator.free(a);
    defer if (connected_address) |a| this.allocator.free(a);

    this.is_powered = adapter_powered;
    if (!adapter_powered) {
        this.renderDisabled();
        return;
    }

    if (num_connected > 0) {
        this.base.addCssClass("connected");
        this.base.removeCssClass("disabled");

        this.replacer.clear();

        const dev_alias = connected_alias orelse "Bluetooth Device";
        const dev_addr = connected_address orelse "";

        this.replacer.addKey("device_alias", dev_alias) catch {};
        this.replacer.addKey("device_address", dev_addr) catch {};
        this.replacer.addKey("controller_alias", adapter_alias orelse "Controller") catch {};
        this.replacer.addKey("controller_address", adapter_address orelse "") catch {};
        this.replacer.addKeyAny("num_connections", @as(i64, @intCast(num_connected))) catch {};
        this.replacer.addKey("status", "connected") catch {};
        if (connected_battery) |bat| {
            this.replacer.addKeyAny("device_battery_percentage", @as(i64, @intCast(bat))) catch {};
            this.replacer.addKeyAny("device_battery", @as(i64, @intCast(bat))) catch {};
            this.replacer.addKeyAny("battery", @as(i64, @intCast(bat))) catch {};
        } else {
            this.replacer.addKey("device_battery_percentage", "") catch {};
            this.replacer.addKey("device_battery", "") catch {};
            this.replacer.addKey("battery", "") catch {};
        }

        var render_buf: [256]u8 = undefined;
        const rendered = if (connected_battery != null and this.format_connected_battery.len > 0)
            this.template_connected_battery.renderBuf(&this.replacer, &render_buf) catch this.format_connected_battery
        else
            this.template_connected.renderBuf(&this.replacer, &render_buf) catch this.format_connected;

        this.base.setText(rendered);

        if (this.template_tooltip) |*tt_tmpl| {
            var tt_buf: [512]u8 = undefined;
            if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
                this.base.setTooltip(tt);
            } else |_| {}
        } else {
            var tt_buf: [256]u8 = undefined;
            const tt = if (connected_battery) |bat|
                mem.print(&tt_buf, "Device: {s} [{s}]\nBattery: {d}%", .{ dev_alias, dev_addr, bat }) catch "Bluetooth"
            else
                mem.print(&tt_buf, "Device: {s} [{s}]", .{ dev_alias, dev_addr }) catch "Bluetooth";
            this.base.setTooltip(tt);
        }
    } else {
        this.base.removeCssClass("connected");
        this.base.removeCssClass("disabled");

        this.replacer.clear();
        this.replacer.addKey("status", "disconnected") catch {};
        this.replacer.addKeyAny("num_connections", @as(i64, 0)) catch {};
        this.replacer.addKey("controller_alias", adapter_alias orelse "Controller") catch {};
        this.replacer.addKey("controller_address", adapter_address orelse "") catch {};
        this.replacer.addKey("device_alias", "") catch {};
        this.replacer.addKey("device_address", "") catch {};
        this.replacer.addKey("device_battery_percentage", "") catch {};
        this.replacer.addKey("device_battery", "") catch {};
        this.replacer.addKey("battery", "") catch {};

        if (this.format.len > 0) {
            var render_buf: [256]u8 = undefined;
            const rendered = this.template_format.renderBuf(&this.replacer, &render_buf) catch this.format;
            this.base.setText(rendered);
        } else {
            this.base.setText("");
        }

        this.base.setTooltip("Bluetooth: Enabled (No devices connected)");
    }
}

fn renderDisabled(this: *BluetoothModule) void {
    this.base.removeCssClass("connected");
    this.base.addCssClass("disabled");

    this.replacer.clear();
    this.replacer.addKey("status", "disabled") catch {};
    this.replacer.addKeyAny("num_connections", @as(i64, 0)) catch {};
    this.replacer.addKey("controller_alias", "Controller") catch {};
    this.replacer.addKey("controller_address", "") catch {};
    this.replacer.addKey("device_alias", "") catch {};
    this.replacer.addKey("device_address", "") catch {};
    this.replacer.addKey("device_battery_percentage", "") catch {};
    this.replacer.addKey("device_battery", "") catch {};
    this.replacer.addKey("battery", "") catch {};

    if (this.format_disabled.len > 0) {
        var render_buf: [256]u8 = undefined;
        const rendered = this.template_disabled.renderBuf(&this.replacer, &render_buf) catch this.format_disabled;
        this.base.setText(rendered);
    } else {
        this.base.setText("");
    }

    this.base.setTooltip("Bluetooth: Disabled or Adapter not found");
}

fn onBluezSignal(connection: ?*gtk.GDBusConnection, sender_name: ?[*:0]const u8, object_path: ?[*:0]const u8, interface_name: ?[*:0]const u8, signal_name: ?[*:0]const u8, parameters: ?*gtk.GVariant, user_data: gtk.gpointer) callconv(.c) void {
    _ = connection;
    _ = sender_name;
    _ = object_path;
    _ = interface_name;
    _ = signal_name;
    _ = parameters;
    const this: *BluetoothModule = @ptrCast(@alignCast(user_data orelse return));
    this.update();
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *BluetoothModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

pub fn togglePower(this: *BluetoothModule) void {
    const c = this.conn orelse return;
    const apath = this.adapter_path orelse "/org/bluez/hci0";
    const new_state = !this.is_powered;

    var buf: [128]u8 = undefined;
    const arg_slice = mem.print(&buf, "('org.bluez.Adapter1', 'Powered', <{s}>)\x00", .{if (new_state) "true" else "false"}) catch return;
    const arg_z: [*:0]const u8 = @ptrCast(arg_slice.ptr);

    var err: ?*anyopaque = null;
    const res = gtk.g_dbus_connection_call_sync(
        c,
        "org.bluez",
        apath.ptr,
        "org.freedesktop.DBus.Properties",
        "Set",
        gtk.g_variant_new_parsed(arg_z),
        null,
        0,
        1000,
        null,
        &err,
    );
    if (res) |r| {
        gtk.g_variant_unref(r);
        this.is_powered = new_state;
        this.update();
    } else {
        if (err) |e| gtk.g_error_free(e);
    }
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    const this: *BluetoothModule = @ptrCast(@alignCast(user_data orelse return false));
    if (btn_num == 3 and this.base.on_click_right == null) {
        this.toggleDevicePopover();
        return true;
    }
    return false;
}

pub fn toggleDevicePopover(this: *BluetoothModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    for (this.device_contexts.items) |ctx| {
        this.allocator.free(ctx.path);
        this.allocator.destroy(ctx);
    }
    this.device_contexts.clearRetainingCapacity();

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 6);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "bluetooth-popover");

        const header_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
        if (header_box) |hb| {
            const title = gtk.gtk_label_new("Bluetooth");
            if (title) |t| {
                gtk.gtk_widget_add_css_class(t, "title");
                gtk.gtk_box_append(@ptrCast(hb), t);
            }

            const pwr_lbl: [:0]const u8 = if (this.is_powered) "On (Turn Off)" else "Off (Turn On)";
            const pwr_btn = gtk.gtk_button_new_with_label(pwr_lbl.ptr);
            if (pwr_btn) |pb| {
                _ = gtk.g_signal_connect_data(pb, "clicked", @ptrCast(&onPowerBtnClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(hb), pb);
            }
            gtk.gtk_box_append(@ptrCast(b), hb);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        const c = this.conn;
        if (c != null) {
            var err: ?*anyopaque = null;
            const res = gtk.g_dbus_connection_call_sync(c.?, "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", null, null, 0, 1000, null, &err);
            if (res) |r| {
                defer gtk.g_variant_unref(r);
                const outer = gtk.g_variant_get_child_value(r, 0);
                if (outer) |out| {
                    defer gtk.g_variant_unref(out);
                    const obj_iter = gtk.g_variant_iter_new(out);
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
                                    if (!mem.eql(u8, mem.span(iface_name_z), "org.bluez.Device1")) continue;

                                    var dev_alias: ?[]const u8 = null;
                                    var dev_connected = false;
                                    var dev_paired = false;

                                    const p_iter = gtk.g_variant_iter_new(props_v);
                                    if (p_iter) |pit| {
                                        defer gtk.g_variant_iter_free(pit);
                                        while (gtk.g_variant_iter_next_value(pit)) |p_entry| {
                                            defer gtk.g_variant_unref(p_entry);
                                            const p_key_v = gtk.g_variant_get_child_value(p_entry, 0);
                                            const p_val_wrapper = gtk.g_variant_get_child_value(p_entry, 1);
                                            defer if (p_key_v) |kv| gtk.g_variant_unref(kv);
                                            defer if (p_val_wrapper) |vw| gtk.g_variant_unref(vw);
                                            if (p_key_v == null or p_val_wrapper == null) continue;

                                            const key_z = gtk.g_variant_get_string(p_key_v, null) orelse continue;
                                            const key = mem.span(key_z);
                                            const p_val = gtk.g_variant_get_variant(p_val_wrapper);
                                            defer if (p_val) |pv| gtk.g_variant_unref(pv);
                                            if (p_val == null) continue;

                                            if (mem.eql(u8, key, "Alias") or mem.eql(u8, key, "Name")) {
                                                if (dev_alias == null) {
                                                    if (gtk.g_variant_get_string(p_val, null)) |sz| {
                                                        dev_alias = mem.span(sz);
                                                    }
                                                }
                                            } else if (mem.eql(u8, key, "Connected")) {
                                                dev_connected = gtk.g_variant_get_boolean(p_val) != 0;
                                            } else if (mem.eql(u8, key, "Paired")) {
                                                dev_paired = gtk.g_variant_get_boolean(p_val) != 0;
                                            }
                                        }
                                    }

                                    if (dev_paired or dev_connected) {
                                        const path_v = gtk.g_variant_get_child_value(obj_entry, 0);
                                        defer if (path_v) |pv| gtk.g_variant_unref(pv);
                                        const path_z = if (path_v) |pv| gtk.g_variant_get_string(pv, null) else null;
                                        if (path_z) |pz| {
                                            const item_row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
                                            if (item_row) |ir| {
                                                var name_buf: [128]u8 = undefined;
                                                const dev_name = dev_alias orelse "Bluetooth Device";
                                                const name_str = mem.printSentinel(&name_buf, "{s} {s}", .{ if (dev_connected) "" else "", dev_name }, 0) catch dev_name;

                                                const lbl = gtk.gtk_label_new(@ptrCast(name_str.ptr));
                                                if (lbl) |l| gtk.gtk_box_append(@ptrCast(ir), l);

                                                const action_text: [:0]const u8 = if (dev_connected) "Disconnect" else "Connect";
                                                const action_btn = gtk.gtk_button_new_with_label(action_text.ptr);
                                                if (action_btn) |ab| {
                                                    const ctx = this.allocator.create(BluetoothDeviceContext) catch continue;
                                                    ctx.* = .{
                                                        .path = this.allocator.dupeSentinel(u8, mem.span(pz), 0) catch {
                                                            this.allocator.destroy(ctx);
                                                            continue;
                                                        },
                                                        .is_connected = dev_connected,
                                                        .mod = this,
                                                    };
                                                    this.device_contexts.append(this.allocator, ctx) catch {
                                                        this.allocator.free(ctx.path);
                                                        this.allocator.destroy(ctx);
                                                        continue;
                                                    };

                                                    _ = gtk.g_signal_connect_data(ab, "clicked", @ptrCast(&onDeviceActionClicked), ctx, null, 0);
                                                    gtk.gtk_box_append(@ptrCast(ir), ab);
                                                }
                                                gtk.gtk_box_append(@ptrCast(b), ir);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                if (err) |e| gtk.g_error_free(e);
            }
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onPowerBtnClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *BluetoothModule = @ptrCast(@alignCast(user_data orelse return));
    this.togglePower();
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onDeviceActionClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const ctx: *BluetoothDeviceContext = @ptrCast(@alignCast(user_data orelse return));
    const conn = ctx.mod.conn orelse return;
    const method: [:0]const u8 = if (ctx.is_connected) "Disconnect" else "Connect";

    _ = gtk.g_dbus_connection_call(
        conn,
        "org.bluez",
        ctx.path.ptr,
        "org.bluez.Device1",
        method.ptr,
        null,
        null,
        0,
        -1,
        null,
        null,
        null,
    );

    if (ctx.mod.popover) |pop| {
        gtk.gtk_popover_popdown(@ptrCast(pop));
    }
    ctx.mod.update();
}
