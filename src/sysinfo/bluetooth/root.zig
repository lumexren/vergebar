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

const Bluetooth = @This();

pub const BluetoothError = @import("BluetoothError.zig").BluetoothError;
pub const AdapterInfo = @import("AdapterInfo.zig");
pub const DeviceInfo = @import("DeviceInfo.zig");

const gdbus = @import("bindings").gdbus;

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const debug = std.debug;

const BLUEZ_SERVICE: [:0]const u8 = "org.bluez";
const BLUEZ_PATH: [:0]const u8 = "/";
const OBJECT_MANAGER_IFACE: [:0]const u8 = "org.freedesktop.DBus.ObjectManager";
const ADAPTER_IFACE = "org.bluez.Adapter1";
const DEVICE_IFACE = "org.bluez.Device1";
const BATTERY_IFACE = "org.bluez.Battery1";

io: Io,
allocator: Allocator,
connection: ?*gdbus.GDBusConnection = null,
owns_connection: bool = false,

pub fn init(io: Io, allocator: Allocator, connection: ?*gdbus.GDBusConnection) Bluetooth {
    var conn = connection;
    var owns = false;
    if (conn == null) {
        conn = gdbus.getBus(.system);
        owns = (conn != null);
    }
    return .{
        .io = io,
        .allocator = allocator,
        .connection = conn,
        .owns_connection = owns,
    };
}

pub fn deinit(this: *Bluetooth) void {
    if (this.owns_connection) {
        if (this.connection) |c| {
            gdbus.g_object_unref(c);
        }
    }
    this.* = undefined;
}

/// Get all Bluetooth adapters via bluez ObjectManager
pub fn getAdapters(this: *Bluetooth) ![]AdapterInfo {
    const conn = this.connection orelse return BluetoothError.ConnectionFailed;
    const res = gdbus.callMethodSync(
        conn,
        BLUEZ_SERVICE,
        BLUEZ_PATH,
        OBJECT_MANAGER_IFACE,
        "GetManagedObjects",
        null,
    ) orelse return BluetoothError.ConnectionFailed;
    defer gdbus.g_variant_unref(res);

    const outer = gdbus.g_variant_get_child_value(res, 0) orelse return BluetoothError.InvalidResponse;
    defer gdbus.g_variant_unref(outer);

    var adapters: ArrayList(AdapterInfo) = .empty;
    errdefer {
        for (adapters.items) |*a| a.deinit(this.allocator);
        adapters.deinit(this.allocator);
    }

    const obj_iter = gdbus.g_variant_iter_new(outer) orelse return BluetoothError.InvalidResponse;
    defer gdbus.g_variant_iter_free(obj_iter);

    while (gdbus.g_variant_iter_next_value(obj_iter)) |obj_entry| {
        defer gdbus.g_variant_unref(obj_entry);
        const path_v = gdbus.g_variant_get_child_value(obj_entry, 0);
        const ifaces_v = gdbus.g_variant_get_child_value(obj_entry, 1);
        defer if (path_v) |pv| gdbus.g_variant_unref(pv);
        defer if (ifaces_v) |iv| gdbus.g_variant_unref(iv);
        if (path_v == null or ifaces_v == null) continue;

        const path = gdbus.asString(path_v) orelse continue;

        const iface_iter = gdbus.g_variant_iter_new(ifaces_v.?);
        if (iface_iter) |iit| {
            defer gdbus.g_variant_iter_free(iit);
            while (gdbus.g_variant_iter_next_value(iit)) |iface_entry| {
                defer gdbus.g_variant_unref(iface_entry);
                const iname_v = gdbus.g_variant_get_child_value(iface_entry, 0);
                const props_v = gdbus.g_variant_get_child_value(iface_entry, 1);
                defer if (iname_v) |inv| gdbus.g_variant_unref(inv);
                defer if (props_v) |prv| gdbus.g_variant_unref(prv);
                if (iname_v == null or props_v == null) continue;

                const iname = gdbus.asString(iname_v) orelse continue;
                if (!mem.eql(u8, iname, ADAPTER_IFACE)) continue;

                var adapter: AdapterInfo = .{ .path = try this.allocator.dupe(u8, path) };
                errdefer adapter.deinit(this.allocator);

                const p_iter = gdbus.g_variant_iter_new(props_v.?);
                if (p_iter) |pit| {
                    defer gdbus.g_variant_iter_free(pit);
                    while (gdbus.g_variant_iter_next_value(pit)) |p_entry| {
                        defer gdbus.g_variant_unref(p_entry);
                        const pk_v = gdbus.g_variant_get_child_value(p_entry, 0);
                        const pv_v = gdbus.g_variant_get_child_value(p_entry, 1);
                        defer if (pk_v) |pkv| gdbus.g_variant_unref(pkv);
                        defer if (pv_v) |pvv| gdbus.g_variant_unref(pvv);
                        if (pk_v == null or pv_v == null) continue;

                        const pk = gdbus.asString(pk_v) orelse continue;
                        const val_v = gdbus.g_variant_get_variant(pv_v.?);
                        defer gdbus.g_variant_unref(val_v);

                        if (mem.eql(u8, pk, "Name")) {
                            if (gdbus.asString(val_v)) |s| adapter.name = try this.allocator.dupe(u8, s);
                        } else if (mem.eql(u8, pk, "Address")) {
                            if (gdbus.asString(val_v)) |s| adapter.address = try this.allocator.dupe(u8, s);
                        } else if (mem.eql(u8, pk, "Powered")) {
                            if (gdbus.asBoolean(val_v)) |b| adapter.powered = b;
                        } else if (mem.eql(u8, pk, "Discoverable")) {
                            if (gdbus.asBoolean(val_v)) |b| adapter.discoverable = b;
                        } else if (mem.eql(u8, pk, "Discovering")) {
                            if (gdbus.asBoolean(val_v)) |b| adapter.discovering = b;
                        }
                    }
                }

                try adapters.append(this.allocator, adapter);
            }
        }
    }

    return adapters.toOwnedSlice(this.allocator);
}

/// Get all Bluetooth devices via bluez ObjectManager
pub fn getDevices(this: *Bluetooth) ![]DeviceInfo {
    const conn = this.connection orelse return BluetoothError.ConnectionFailed;
    const res = gdbus.callMethodSync(
        conn,
        BLUEZ_SERVICE,
        BLUEZ_PATH,
        OBJECT_MANAGER_IFACE,
        "GetManagedObjects",
        null,
    ) orelse return BluetoothError.ConnectionFailed;
    defer gdbus.g_variant_unref(res);

    const outer = gdbus.g_variant_get_child_value(res, 0) orelse return BluetoothError.InvalidResponse;
    defer gdbus.g_variant_unref(outer);

    var devices: ArrayList(DeviceInfo) = .empty;
    errdefer {
        for (devices.items) |*d| d.deinit(this.allocator);
        devices.deinit(this.allocator);
    }

    const obj_iter = gdbus.g_variant_iter_new(outer) orelse return BluetoothError.InvalidResponse;
    defer gdbus.g_variant_iter_free(obj_iter);

    while (gdbus.g_variant_iter_next_value(obj_iter)) |obj_entry| {
        defer gdbus.g_variant_unref(obj_entry);
        const path_v = gdbus.g_variant_get_child_value(obj_entry, 0);
        const ifaces_v = gdbus.g_variant_get_child_value(obj_entry, 1);
        defer if (path_v) |pv| gdbus.g_variant_unref(pv);
        defer if (ifaces_v) |iv| gdbus.g_variant_unref(iv);
        if (path_v == null or ifaces_v == null) continue;

        const path = gdbus.asString(path_v) orelse continue;

        var dev: ?DeviceInfo = null;
        var bat_pct: ?u8 = null;

        const iface_iter = gdbus.g_variant_iter_new(ifaces_v.?);
        if (iface_iter) |iit| {
            defer gdbus.g_variant_iter_free(iit);
            while (gdbus.g_variant_iter_next_value(iit)) |iface_entry| {
                defer gdbus.g_variant_unref(iface_entry);
                const iname_v = gdbus.g_variant_get_child_value(iface_entry, 0);
                const props_v = gdbus.g_variant_get_child_value(iface_entry, 1);
                defer if (iname_v) |inv| gdbus.g_variant_unref(inv);
                defer if (props_v) |prv| gdbus.g_variant_unref(prv);
                if (iname_v == null or props_v == null) continue;

                const iname = gdbus.asString(iname_v) orelse continue;

                if (mem.eql(u8, iname, DEVICE_IFACE)) {
                    if (dev == null) {
                        dev = .{ .path = try this.allocator.dupe(u8, path) };
                    }
                    const p_iter = gdbus.g_variant_iter_new(props_v.?);
                    if (p_iter) |pit| {
                        defer gdbus.g_variant_iter_free(pit);
                        while (gdbus.g_variant_iter_next_value(pit)) |p_entry| {
                            defer gdbus.g_variant_unref(p_entry);
                            const pk_v = gdbus.g_variant_get_child_value(p_entry, 0);
                            const pv_v = gdbus.g_variant_get_child_value(p_entry, 1);
                            defer if (pk_v) |pkv| gdbus.g_variant_unref(pkv);
                            defer if (pv_v) |pvv| gdbus.g_variant_unref(pvv);
                            if (pk_v == null or pv_v == null) continue;

                            const pk = gdbus.asString(pk_v) orelse continue;
                            const val_v = gdbus.g_variant_get_variant(pv_v.?);
                            defer gdbus.g_variant_unref(val_v);

                            if (mem.eql(u8, pk, "Address")) {
                                if (gdbus.asString(val_v)) |s| dev.?.address = try this.allocator.dupe(u8, s);
                            } else if (mem.eql(u8, pk, "Name")) {
                                if (gdbus.asString(val_v)) |s| dev.?.name = try this.allocator.dupe(u8, s);
                            } else if (mem.eql(u8, pk, "Alias")) {
                                if (gdbus.asString(val_v)) |s| dev.?.alias = try this.allocator.dupe(u8, s);
                            } else if (mem.eql(u8, pk, "Icon")) {
                                if (gdbus.asString(val_v)) |s| dev.?.icon = try this.allocator.dupe(u8, s);
                            } else if (mem.eql(u8, pk, "Paired")) {
                                if (gdbus.asBoolean(val_v)) |b| dev.?.paired = b;
                            } else if (mem.eql(u8, pk, "Connected")) {
                                if (gdbus.asBoolean(val_v)) |b| dev.?.connected = b;
                            } else if (mem.eql(u8, pk, "Trusted")) {
                                if (gdbus.asBoolean(val_v)) |b| dev.?.trusted = b;
                            } else if (mem.eql(u8, pk, "Blocked")) {
                                if (gdbus.asBoolean(val_v)) |b| dev.?.blocked = b;
                            }
                        }
                    }
                } else if (mem.eql(u8, iname, BATTERY_IFACE)) {
                    const p_iter = gdbus.g_variant_iter_new(props_v.?);
                    if (p_iter) |pit| {
                        defer gdbus.g_variant_iter_free(pit);
                        while (gdbus.g_variant_iter_next_value(pit)) |p_entry| {
                            defer gdbus.g_variant_unref(p_entry);
                            const pk_v = gdbus.g_variant_get_child_value(p_entry, 0);
                            const pv_v = gdbus.g_variant_get_child_value(p_entry, 1);
                            defer if (pk_v) |pkv| gdbus.g_variant_unref(pkv);
                            defer if (pv_v) |pvv| gdbus.g_variant_unref(pvv);
                            if (pk_v == null or pv_v == null) continue;

                            const pk = gdbus.asString(pk_v) orelse continue;
                            if (mem.eql(u8, pk, "Percentage")) {
                                const val_v = gdbus.g_variant_get_variant(pv_v.?);
                                defer gdbus.g_variant_unref(val_v);
                                if (gdbus.asByte(val_v)) |b| bat_pct = b;
                            }
                        }
                    }
                }
            }
        }

        if (dev) |mut_d| {
            var d = mut_d;
            if (bat_pct) |bp| d.battery = bp;
            try devices.append(this.allocator, d);
        }
    }

    return devices.toOwnedSlice(this.allocator);
}

/// Get only connected devices
pub fn getConnectedDevices(this: *Bluetooth) ![]DeviceInfo {
    var all = try this.getDevices();
    var count: usize = 0;
    for (all) |d| {
        if (d.connected) {
            all[count] = d;
            count += 1;
        } else {
            var mutable_d = d;
            mutable_d.deinit(this.allocator);
        }
    }
    return this.allocator.realloc(all, count);
}

const testing = std.testing;

test "AdapterInfo.deinit" {
    var adapter: AdapterInfo = .{
        .path = try testing.allocator.dupe(u8, "/org/bluez/hci0"),
        .name = try testing.allocator.dupe(u8, "hci0"),
        .address = try testing.allocator.dupe(u8, "00:11:22:33:44:55"),
    };
    adapter.deinit(testing.allocator);
}

test "DeviceInfo.deinit" {
    var device: DeviceInfo = .{
        .path = try testing.allocator.dupe(u8, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"),
        .name = try testing.allocator.dupe(u8, "Test Device"),
        .address = try testing.allocator.dupe(u8, "AA:BB:CC:DD:EE:FF"),
    };
    device.deinit(testing.allocator);
}

test "live bluetooth gdbus" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var bt: Bluetooth = .init(io, testing.allocator, null);
    defer bt.deinit();

    const adapters = bt.getAdapters() catch |err| switch (err) {
        BluetoothError.ConnectionFailed => return,
        else => return err,
    };
    defer {
        for (adapters) |*a| a.deinit(testing.allocator);
        testing.allocator.free(adapters);
    }

    const devices = bt.getDevices() catch |err| switch (err) {
        BluetoothError.ConnectionFailed => return,
        else => return err,
    };
    defer {
        for (devices) |*d| d.deinit(testing.allocator);
        testing.allocator.free(devices);
    }
}
