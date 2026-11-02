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

const plume = @import("plume");
const Connection = plume.Connection;
const Proxy = plume.Proxy;
const Value = plume.Value;
const GPath = Value.GPath;
const GVariant = Value.GVariant;

const std = @import("std");
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const StringHashMap = std.StringHashMap;
const HashMap = std.HashMap;
const hash_map = std.hash_map;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Wyhash = std.hash.Wyhash;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;
const process = std.process;
const debug = std.debug;

const BLUEZ_SERVICE: [:0]const u8 = "org.bluez";
const BLUEZ_PATH: [:0]const u8 = "/";
const OBJECT_MANAGER_IFACE: [:0]const u8 = "org.freedesktop.DBus.ObjectManager";
const ADAPTER_IFACE: [:0]const u8 = "org.bluez.Adapter1";
const DEVICE_IFACE: [:0]const u8 = "org.bluez.Device1";
const BATTERY_IFACE: [:0]const u8 = "org.bluez.Battery1";

io: Io,
allocator: Allocator,
connection: *Connection,
proxy: Proxy,

pub fn init(io: Io, allocator: Allocator, connection: *Connection) Bluetooth {
    return .{
        .io = io,
        .allocator = allocator,
        .connection = connection,
        .proxy = .init(connection, BLUEZ_SERVICE, BLUEZ_PATH, OBJECT_MANAGER_IFACE),
    };
}

pub fn deinit(self: *Bluetooth) void {
    self.* = undefined;
}

const GPathContext = struct {
    pub fn hash(self: @This(), s: GPath) u64 {
        _ = self;
        return Wyhash.hash(0, s.s);
    }
    pub fn eql(self: @This(), a: GPath, b: GPath) bool {
        _ = self;
        return mem.eql(u8, a.s, b.s);
    }
};

const ManagedObjects = HashMap(GPath, StringHashMap(StringHashMap(GVariant)), GPathContext, hash_map.default_max_load_percentage);

/// Get all Bluetooth adapters via bluez ObjectManager
pub fn getAdapters(self: *Bluetooth) ![]AdapterInfo {
    var res = self.proxy.call("GetManagedObjects", .{}) catch return BluetoothError.ConnectionFailed;
    defer res.deinit();

    var adapters: ArrayList(AdapterInfo) = .empty;
    errdefer {
        for (adapters.items) |*a| a.deinit(self.allocator);
        adapters.deinit(self.allocator);
    }

    var arena: ArenaAllocator = .init(self.allocator);
    defer arena.deinit();

    var dec: plume.Decoder = .fromMessage(arena.allocator(), res.message);
    var objects = dec.decodeAlloc(ManagedObjects) catch return BluetoothError.InvalidResponse;

    var it = objects.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.s;
        var iface_map = entry.value_ptr.*;

        if (iface_map.get(ADAPTER_IFACE)) |props| {
            var adapter = AdapterInfo{ .path = try self.allocator.dupe(u8, path) };
            errdefer adapter.deinit(self.allocator);

            var prop_it = props.iterator();
            while (prop_it.next()) |prop| {
                const v = prop.value_ptr.*;
                const inner = if (v == .variant) v.variant.* else v;
                if (mem.eql(u8, prop.key_ptr.*, "Name")) {
                    if (inner == .string) adapter.name = try self.allocator.dupe(u8, inner.string.s);
                } else if (mem.eql(u8, prop.key_ptr.*, "Address")) {
                    if (inner == .string) adapter.address = try self.allocator.dupe(u8, inner.string.s);
                } else if (mem.eql(u8, prop.key_ptr.*, "Powered")) {
                    if (inner == .boolean) adapter.powered = inner.boolean;
                } else if (mem.eql(u8, prop.key_ptr.*, "Discoverable")) {
                    if (inner == .boolean) adapter.discoverable = inner.boolean;
                } else if (mem.eql(u8, prop.key_ptr.*, "Discovering")) {
                    if (inner == .boolean) adapter.discovering = inner.boolean;
                }
            }

            try adapters.append(self.allocator, adapter);
        }
    }

    return adapters.toOwnedSlice(self.allocator);
}

/// Get all Bluetooth devices via bluez ObjectManager
pub fn getDevices(self: *Bluetooth) ![]DeviceInfo {
    var res = self.proxy.call("GetManagedObjects", .{}) catch return BluetoothError.ConnectionFailed;
    defer res.deinit();

    var devices: ArrayList(DeviceInfo) = .empty;
    errdefer {
        for (devices.items) |*d| d.deinit(self.allocator);
        devices.deinit(self.allocator);
    }

    var arena: ArenaAllocator = .init(self.allocator);
    defer arena.deinit();

    var dec: plume.Decoder = .fromMessage(arena.allocator(), res.message);
    var objects = dec.decodeAlloc(ManagedObjects) catch return BluetoothError.InvalidResponse;

    var it = objects.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.s;
        var iface_map = entry.value_ptr.*;

        if (iface_map.get(DEVICE_IFACE)) |props| {
            var device = DeviceInfo{ .path = try self.allocator.dupe(u8, path) };
            errdefer device.deinit(self.allocator);

            var prop_it = props.iterator();
            while (prop_it.next()) |prop| {
                const v = prop.value_ptr.*;
                const inner = if (v == .variant) v.variant.* else v;
                if (mem.eql(u8, prop.key_ptr.*, "Address")) {
                    if (inner == .string) device.address = try self.allocator.dupe(u8, inner.string.s);
                } else if (mem.eql(u8, prop.key_ptr.*, "Name")) {
                    if (inner == .string) device.name = try self.allocator.dupe(u8, inner.string.s);
                } else if (mem.eql(u8, prop.key_ptr.*, "Alias")) {
                    if (inner == .string) device.alias = try self.allocator.dupe(u8, inner.string.s);
                } else if (mem.eql(u8, prop.key_ptr.*, "Icon")) {
                    if (inner == .string) device.icon = try self.allocator.dupe(u8, inner.string.s);
                } else if (mem.eql(u8, prop.key_ptr.*, "Paired")) {
                    if (inner == .boolean) device.paired = inner.boolean;
                } else if (mem.eql(u8, prop.key_ptr.*, "Connected")) {
                    if (inner == .boolean) device.connected = inner.boolean;
                } else if (mem.eql(u8, prop.key_ptr.*, "Trusted")) {
                    if (inner == .boolean) device.trusted = inner.boolean;
                } else if (mem.eql(u8, prop.key_ptr.*, "Blocked")) {
                    if (inner == .boolean) device.blocked = inner.boolean;
                }
            }

            if (iface_map.get(BATTERY_IFACE)) |bat_props| {
                var bat_it = bat_props.iterator();
                while (bat_it.next()) |prop| {
                    if (mem.eql(u8, prop.key_ptr.*, "Percentage")) {
                        const v = prop.value_ptr.*;
                        const inner = if (v == .variant) v.variant.* else v;
                        if (inner == .byte) {
                            device.battery = inner.byte;
                        } else if (inner == .uint32) {
                            device.battery = @intCast(inner.uint32);
                        } else if (inner == .int32) {
                            device.battery = @intCast(inner.int32);
                        }
                    }
                }
            }

            try devices.append(self.allocator, device);
        }
    }

    return devices.toOwnedSlice(self.allocator);
}

/// Get only connected devices
pub fn getConnectedDevices(self: *Bluetooth) ![]DeviceInfo {
    var all = try self.getDevices();
    var count: usize = 0;
    for (all) |d| {
        if (d.connected) {
            all[count] = d;
            count += 1;
        } else {
            var mutable_d = d;
            mutable_d.deinit(self.allocator);
        }
    }
    return self.allocator.realloc(all, count);
}

const testing = std.testing;

test "AdapterInfo.deinit" {
    var adapter = AdapterInfo{
        .path = try testing.allocator.dupe(u8, "/org/bluez/hci0"),
        .name = try testing.allocator.dupe(u8, "hci0"),
        .address = try testing.allocator.dupe(u8, "00:11:22:33:44:55"),
    };
    adapter.deinit(testing.allocator);
}

test "DeviceInfo.deinit" {
    var device = DeviceInfo{
        .path = try testing.allocator.dupe(u8, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"),
        .name = try testing.allocator.dupe(u8, "Test Device"),
        .address = try testing.allocator.dupe(u8, "AA:BB:CC:DD:EE:FF"),
    };
    device.deinit(testing.allocator);
}

test "live bluetooth dbus" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var environ_map: process.Environ.Map = .init(testing.allocator);
    defer environ_map.deinit();

    var conn: Connection = Connection.init(io, testing.allocator, .System, &environ_map) catch |err| {
        debug.print("\nConnection error: {any}\n", .{err});
        return;
    };
    defer conn.close();

    var bt: Bluetooth = .init(io, testing.allocator, &conn);
    defer bt.deinit();

    const adapters = bt.getAdapters() catch |err| switch (err) {
        BluetoothError.ConnectionFailed => {
            debug.print("\nBlueZ service not available, skipping live test\n", .{});
            return;
        },
        else => return err,
    };
    defer {
        for (adapters) |*a| a.deinit(testing.allocator);
        testing.allocator.free(adapters);
    }

    debug.print("\nFound {d} adapters:\n", .{adapters.len});
    for (adapters) |a| {
        debug.print("Adapter path: {s}, name: {s}, address: {s}, powered: {}\n", .{ a.path, a.name orelse "null", a.address orelse "null", a.powered });
    }

    const devices = bt.getDevices() catch |err| switch (err) {
        BluetoothError.ConnectionFailed => return,
        else => return err,
    };
    defer {
        for (devices) |*d| d.deinit(testing.allocator);
        testing.allocator.free(devices);
    }

    debug.print("\nFound {d} devices:\n", .{devices.len});
    for (devices) |d| {
        debug.print("Device path: {s}, name: {s}, connected: {}, battery: {any}\n", .{ d.path, d.name orelse "null", d.connected, d.battery });
    }
}
