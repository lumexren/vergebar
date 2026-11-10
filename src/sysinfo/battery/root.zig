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

pub const BatteryStat = struct {
    capacity: u8,
    status: [32]u8,
    status_len: u8,
    power_watts: ?f64 = null,
    time_to_minutes: ?u32 = null,
    health: ?u8 = null,
    cycles: ?u32 = null,

    pub fn statusSlice(this: *const BatteryStat) []const u8 {
        return this.status[0..this.status_len];
    }
};

const sysfs = @import("utils").sysfs;
const POWER_SUPPLY_PATH = "/sys/class/power_supply";

/// Reads battery capacity and status directly from sysfs without requiring D-Bus.
pub fn readBatterySysfs(io: Io, preferred_battery: ?[]const u8) ?BatteryStat {
    if (preferred_battery) |name| {
        if (mem.eql(u8, name, "all")) {
            return readAggregateBatteries(io);
        }
        return readSysfsDevice(io, name);
    }

    var dir = Io.Dir.openDirAbsolute(io, POWER_SUPPLY_PATH, .{ .iterate = true }) catch {
        // Fallback to standard names BAT0/BAT1 if directory iteration fails
        return readSysfsDevice(io, "BAT0") orelse readSysfsDevice(io, "BAT1");
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (mem.startsWith(u8, entry.name, "BAT")) {
            if (readSysfsDevice(io, entry.name)) |stat| return stat;
        }
    }
    return readSysfsDevice(io, "BAT0");
}

fn readSysfsU64(io: Io, name: []const u8, file_name: []const u8) ?u64 {
    var path_buf: [128]u8 = undefined;
    const path = mem.print(&path_buf, "{s}/{s}/{s}", .{ POWER_SUPPLY_PATH, name, file_name }) catch return null;
    var val_buf: [32]u8 = undefined;
    const s = sysfs.readLine(io, path, &val_buf) orelse return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn readAggregateBatteries(io: Io) ?BatteryStat {
    var dir = Io.Dir.openDirAbsolute(io, POWER_SUPPLY_PATH, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var count: u32 = 0;
    var cap_sum: u32 = 0;
    var power_sum: f64 = 0.0;
    var has_power = false;
    var is_discharging = false;
    var is_charging = false;
    var cycles_sum: u32 = 0;
    var has_cycles = false;

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (mem.startsWith(u8, entry.name, "BAT")) {
            if (readSysfsDevice(io, entry.name)) |stat| {
                count += 1;
                cap_sum += stat.capacity;
                if (stat.power_watts) |pw| {
                    power_sum += pw;
                    has_power = true;
                }
                if (stat.cycles) |cy| {
                    cycles_sum += cy;
                    has_cycles = true;
                }
                const sl = stat.statusSlice();
                if (mem.startsWith(u8, sl, "Discharg")) is_discharging = true;
                if (mem.startsWith(u8, sl, "Charg")) is_charging = true;
            }
        }
    }

    if (count == 0) return null;

    var stat: BatteryStat = .{
        .capacity = @intCast(cap_sum / count),
        .status = undefined,
        .status_len = 0,
        .power_watts = if (has_power) power_sum else null,
        .cycles = if (has_cycles) cycles_sum else null,
    };

    const status_str: []const u8 = if (is_discharging)
        "Discharging"
    else if (is_charging)
        "Charging"
    else
        "Full";

    const copy_len = @min(status_str.len, stat.status.len);
    @memcpy(stat.status[0..copy_len], status_str[0..copy_len]);
    stat.status_len = @intCast(copy_len);

    return stat;
}

fn readSysfsDevice(io: Io, name: []const u8) ?BatteryStat {
    var cap_path_buf: [128]u8 = undefined;
    var stat_path_buf: [128]u8 = undefined;

    const cap_path = mem.print(&cap_path_buf, "{s}/{s}/capacity", .{ POWER_SUPPLY_PATH, name }) catch return null;
    const stat_path = mem.print(&stat_path_buf, "{s}/{s}/status", .{ POWER_SUPPLY_PATH, name }) catch return null;

    var cap_buf: [16]u8 = undefined;
    const cap_str = sysfs.readLine(io, cap_path, &cap_buf) orelse return null;
    const cap = std.fmt.parseInt(u8, cap_str, 10) catch 100;

    var stat: BatteryStat = .{
        .capacity = cap,
        .status = undefined,
        .status_len = 0,
    };

    var s_buf: [32]u8 = undefined;
    if (sysfs.readLine(io, stat_path, &s_buf)) |s| {
        const copy_len = @min(s.len, stat.status.len);
        @memcpy(stat.status[0..copy_len], s[0..copy_len]);
        stat.status_len = @intCast(copy_len);
    } else {
        const default_str = "Full";
        @memcpy(stat.status[0..default_str.len], default_str);
        stat.status_len = default_str.len;
    }

    const power_now = readSysfsU64(io, name, "power_now");
    const current_now = readSysfsU64(io, name, "current_now");
    const voltage_now = readSysfsU64(io, name, "voltage_now");
    const energy_now = readSysfsU64(io, name, "energy_now");
    const charge_now = readSysfsU64(io, name, "charge_now");
    const energy_full = readSysfsU64(io, name, "energy_full");
    const charge_full = readSysfsU64(io, name, "charge_full");
    const energy_full_design = readSysfsU64(io, name, "energy_full_design");
    const charge_full_design = readSysfsU64(io, name, "charge_full_design");
    const cycle_count = readSysfsU64(io, name, "cycle_count");

    var power_uW: ?u64 = power_now;
    if (power_uW == null and current_now != null and voltage_now != null) {
        power_uW = (current_now.? * voltage_now.?) / 1_000_000;
    }

    var energy_uWh: ?u64 = energy_now;
    if (energy_uWh == null and charge_now != null and voltage_now != null) {
        energy_uWh = (charge_now.? * voltage_now.?) / 1_000_000;
    }

    var full_uWh: ?u64 = energy_full;
    if (full_uWh == null and charge_full != null and voltage_now != null) {
        full_uWh = (charge_full.? * voltage_now.?) / 1_000_000;
    }

    var design_uWh: ?u64 = energy_full_design;
    if (design_uWh == null and charge_full_design != null and voltage_now != null) {
        design_uWh = (charge_full_design.? * voltage_now.?) / 1_000_000;
    }

    if (power_uW) |puw| {
        stat.power_watts = @as(f64, @floatFromInt(puw)) / 1_000_000.0;
    }

    if (full_uWh != null and design_uWh != null and design_uWh.? > 0) {
        stat.health = @intCast(@min(100, (full_uWh.? * 100) / design_uWh.?));
    }

    const s_slice = stat.statusSlice();
    if (power_uW != null and power_uW.? > 0) {
        if (mem.startsWith(u8, s_slice, "Discharg") and energy_uWh != null) {
            stat.time_to_minutes = @intCast((energy_uWh.? * 60) / power_uW.?);
        } else if (mem.startsWith(u8, s_slice, "Charg") and energy_uWh != null and full_uWh != null and full_uWh.? > energy_uWh.?) {
            stat.time_to_minutes = @intCast(((full_uWh.? - energy_uWh.?) * 60) / power_uW.?);
        }
    }

    stat.cycles = if (cycle_count) |c| @intCast(c) else null;

    return stat;
}

const gdbus = @import("bindings").gdbus;

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
connection: ?*gdbus.GDBusConnection = null,
owns_connection: bool = false,

pub fn init(io: Io, allocator: Allocator, connection: ?*gdbus.GDBusConnection) Battery {
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

pub fn deinit(this: *Battery) void {
    if (this.owns_connection) {
        if (this.connection) |c| {
            gdbus.g_object_unref(c);
        }
    }
    this.* = undefined;
}

/// Get all batteries from UPower
pub fn getBatteries(this: *Battery) ![]BatteryInfo {
    const conn = this.connection orelse return BatteryError.ConnectionFailed;
    const res = gdbus.callMethodSync(
        conn,
        UPOWER_SERVICE,
        UPOWER_PATH,
        UPOWER_IFACE,
        "EnumerateDevices",
        null,
    ) orelse return BatteryError.ConnectionFailed;
    defer gdbus.g_variant_unref(res);

    const outer = gdbus.g_variant_get_child_value(res, 0) orelse return BatteryError.InvalidResponse;
    defer gdbus.g_variant_unref(outer);

    const iter = gdbus.g_variant_iter_new(outer) orelse return BatteryError.InvalidResponse;
    defer gdbus.g_variant_iter_free(iter);

    var batteries: ArrayList(BatteryInfo) = .empty;
    errdefer {
        for (batteries.items) |*b| b.deinit(this.allocator);
        batteries.deinit(this.allocator);
    }

    while (gdbus.g_variant_iter_next_value(iter)) |dev_val| {
        defer gdbus.g_variant_unref(dev_val);
        const path_z = gdbus.g_variant_get_string(dev_val, null);
        const path = mem.span(path_z);
        if (this.getDeviceInfo(path)) |info| {
            if (info.device_type == .battery) {
                try batteries.append(this.allocator, info);
            } else {
                var mut = info;
                mut.deinit(this.allocator);
            }
        } else |_| {}
    }

    return batteries.toOwnedSlice(this.allocator);
}

/// Get the display device (primary battery)
pub fn getDisplayDevice(this: *Battery) !BatteryInfo {
    const conn = this.connection orelse return BatteryError.ConnectionFailed;
    const res = gdbus.callMethodSync(
        conn,
        UPOWER_SERVICE,
        UPOWER_PATH,
        UPOWER_IFACE,
        "GetDisplayDevice",
        null,
    ) orelse return BatteryError.ConnectionFailed;
    defer gdbus.g_variant_unref(res);

    const outer = gdbus.g_variant_get_child_value(res, 0) orelse return BatteryError.InvalidResponse;
    defer gdbus.g_variant_unref(outer);

    const path_z = gdbus.g_variant_get_string(outer, null);
    const path = mem.span(path_z);

    return this.getDeviceInfo(path);
}

fn getDeviceInfo(this: *Battery, path: []const u8) !BatteryInfo {
    const conn = this.connection orelse return BatteryError.ConnectionFailed;
    var path_buf: [257]u8 = undefined;
    const path_z = mem.printSentinel(&path_buf, "{s}", .{path}, 0) catch return BatteryError.InvalidResponse;

    var info: BatteryInfo = .{
        .path = try this.allocator.dupe(u8, path),
    };
    errdefer info.deinit(this.allocator);

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "Type")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asUint32(v)) |u| info.device_type = @fromBackingInt(@intCast(u));
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "State")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asUint32(v)) |u| info.state = @fromBackingInt(@intCast(@min(u, 6)));
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "Percentage")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asDouble(v)) |d| info.percentage = d;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "Energy")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asDouble(v)) |d| info.energy = d;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "EnergyFull")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asDouble(v)) |d| info.energy_full = d;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "EnergyFullDesign")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asDouble(v)) |d| info.energy_full_design = d;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "EnergyRate")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asDouble(v)) |d| info.energy_rate = d;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "Voltage")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asDouble(v)) |d| info.voltage = d;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "TimeToEmpty")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asInt64(v)) |i| info.time_to_empty = i;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "TimeToFull")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asInt64(v)) |i| info.time_to_full = i;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "IsPresent")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asBoolean(v)) |b| info.is_present = b;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "IsRechargeable")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asBoolean(v)) |b| info.is_rechargeable = b;
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "NativePath")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asString(v)) |s| {
            if (s.len > 0) info.native_path = try this.allocator.dupe(u8, s);
        }
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "Model")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asString(v)) |s| {
            if (s.len > 0) info.model = try this.allocator.dupe(u8, s);
        }
    }

    if (gdbus.getPropertySync(conn, UPOWER_SERVICE, path_z, DEVICE_IFACE, "Vendor")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asString(v)) |s| {
            if (s.len > 0) info.vendor = try this.allocator.dupe(u8, s);
        }
    }

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
