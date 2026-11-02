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

const Battery = @This();

pub const BatteryInfo = @import("BatteryInfo.zig");
pub const BatteryError = @import("BatteryError.zig").BatteryError;
pub const BatteryState = @import("BatteryState.zig").BatteryState;
pub const DeviceType = @import("DeviceType.zig").DeviceType;

const plume = @import("plume");
const Connection = plume.Connection;
const Proxy = plume.Proxy;
const Value = plume.Value;
const GStr = Value.GStr;
const GPath = Value.GPath;
const GVariant = Value.GVariant;

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const UPOWER_SERVICE: [:0]const u8 = "org.freedesktop.UPower";
const UPOWER_PATH: [:0]const u8 = "/org/freedesktop/UPower";
const UPOWER_IFACE: [:0]const u8 = "org.freedesktop.UPower";
const DEVICE_IFACE: [:0]const u8 = "org.freedesktop.UPower.Device";

io: Io,
allocator: Allocator,
connection: *Connection,
proxy: Proxy,

pub inline fn init(io: Io, allocator: Allocator, connection: *Connection) Battery {
    return .{
        .io = io,
        .allocator = allocator,
        .connection = connection,
        .proxy = .init(connection, UPOWER_SERVICE, UPOWER_PATH, UPOWER_IFACE),
    };
}

pub fn deinit(self: *Battery) void {
    self.* = undefined;
}

/// Get all batteries from UPower
pub fn getBatteries(self: *Battery) ![]BatteryInfo {
    var res = self.proxy.call("EnumerateDevices", .{}) catch return BatteryError.ConnectionFailed;
    defer res.deinit();

    const devices = res.expectAlloc([]GPath) catch return BatteryError.InvalidResponse;
    defer {
        for (devices) |p| self.allocator.free(p.s);
        self.allocator.free(devices);
    }

    var batteries: ArrayList(BatteryInfo) = .empty;
    errdefer {
        for (batteries.items) |*b| b.deinit(self.allocator);
        batteries.deinit(self.allocator);
    }

    for (devices) |dev_path| {
        if (self.getDeviceInfo(dev_path.s)) |info| {
            if (info.device_type == .battery) {
                try batteries.append(self.allocator, info);
            } else {
                var mut = info;
                mut.deinit(self.allocator);
            }
        } else |_| {}
    }

    return batteries.toOwnedSlice(self.allocator);
}

/// Get the display device (primary battery)
pub fn getDisplayDevice(self: *Battery) !BatteryInfo {
    var res = self.proxy.call("GetDisplayDevice", .{}) catch return BatteryError.ConnectionFailed;
    defer res.deinit();

    const path = res.expectAlloc(GPath) catch return BatteryError.InvalidResponse;
    defer self.allocator.free(path.s);

    return self.getDeviceInfo(path.s);
}

fn getDeviceInfo(self: *Battery, path: []const u8) !BatteryInfo {
    var path_buf: [257]u8 = undefined;
    const path_z = mem.printSentinel(&path_buf, "{s}", .{path}, 0) catch return BatteryError.InvalidResponse;

    var dev_proxy: Proxy = .init(self.connection, UPOWER_SERVICE, path_z, DEVICE_IFACE);

    var info = BatteryInfo{
        .path = try self.allocator.dupe(u8, path),
    };
    errdefer info.deinit(self.allocator);

    if (dev_proxy.getProperty(GVariant, "Type")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .uint32) info.device_type = @fromBackingInt(@intCast(v.uint32));
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "State")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .uint32) info.state = @fromBackingInt(@intCast(@min(v.uint32, 6)));
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "Percentage")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .double) info.percentage = v.double;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "Energy")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .double) info.energy = v.double;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "EnergyFull")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .double) info.energy_full = v.double;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "EnergyFullDesign")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .double) info.energy_full_design = v.double;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "EnergyRate")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .double) info.energy_rate = v.double;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "Voltage")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .double) info.voltage = v.double;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "TimeToEmpty")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .int64) info.time_to_empty = v.int64;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "TimeToFull")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .int64) info.time_to_full = v.int64;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "IsPresent")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .boolean) info.is_present = v.boolean;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "IsRechargeable")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .boolean) info.is_rechargeable = v.boolean;
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "NativePath")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .string and v.string.s.len > 0) {
            info.native_path = try self.allocator.dupe(u8, v.string.s);
        }
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "Model")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .string and v.string.s.len > 0) {
            info.model = try self.allocator.dupe(u8, v.string.s);
        }
    } else |_| {}

    if (dev_proxy.getProperty(GVariant, "Vendor")) |v| {
        var mut = v;
        defer mut.deinit(self.allocator);
        if (v == .string and v.string.s.len > 0) {
            info.vendor = try self.allocator.dupe(u8, v.string.s);
        }
    } else |_| {}

    if (info.energy_full > 0 and info.energy_full_design > 0) {
        const health_pct = info.energy_full / info.energy_full_design * 100;
        info.health = @intFromFloat(@min(health_pct, 100));
    }

    return info;
}

const testing = std.testing;

test "getBatteries - integration" {
    _ = testing;
}
