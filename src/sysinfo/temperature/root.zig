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

const Temperature = @This();

pub const TemperatureError = @import("TemperatureError.zig").TemperatureError;
pub const TemperatureInfo = @import("TemperatureInfo.zig").TemperatureInfo;
pub const Sensor = @import("TemperatureInfo.zig").Sensor;
const sysfs = @import("../common/sysfs.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const HWMON_PATH = "/sys/class/hwmon";
pub const THERMAL_PATH = "/sys/class/thermal";

io: Io,
allocator: Allocator,
filter_sensor: ?[]const u8 = null,
info: TemperatureInfo = .{},
sensors: ArrayList(Sensor),

pub fn init(io: Io, allocator: Allocator, filter_sensor: ?[]const u8) Temperature {
    return .{
        .io = io,
        .allocator = allocator,
        .filter_sensor = filter_sensor,
        .info = .{},
        .sensors = .empty,
    };
}

pub fn deinit(this: *Temperature) void {
    this.freeSensors();
    this.sensors.deinit(this.allocator);
}

pub fn clear(this: *Temperature) void {
    this.freeSensors();
    this.sensors.clearRetainingCapacity();
}

fn freeSensors(this: *Temperature) void {
    for (this.sensors.items) |s| {
        this.allocator.free(s.name);
    }
}

pub fn update(this: *Temperature) !void {
    this.clear();

    var hwmon_scanned = false;
    if (Dir.openDirAbsolute(this.io, HWMON_PATH, .{ .iterate = true })) |hwmon_dir_val| {
        var hwmon_dir = hwmon_dir_val;
        defer hwmon_dir.close(this.io);
        this.scanHwmon(hwmon_dir) catch {};
        hwmon_scanned = true;
    } else |_| {}

    if (this.sensors.items.len == 0) {
        if (Dir.openDirAbsolute(this.io, THERMAL_PATH, .{ .iterate = true })) |thermal_dir_val| {
            var thermal_dir = thermal_dir_val;
            defer thermal_dir.close(this.io);
            this.scanThermal(thermal_dir) catch {};
        } else |_| {}
    }

    if (this.sensors.items.len == 0) {
        if (!hwmon_scanned) return TemperatureError.HwmonNotFound;
        return TemperatureError.SensorNotFound;
    }

    var target_sensor: ?Sensor = null;
    var overall_max: f64 = -273.15;

    for (this.sensors.items) |sensor| {
        if (sensor.celsius > overall_max) overall_max = sensor.celsius;

        if (this.filter_sensor) |filter| {
            if (containsIgnoreCase(sensor.name, filter)) {
                if (target_sensor == null or sensor.celsius > target_sensor.?.celsius) {
                    target_sensor = sensor;
                }
            }
        }
    }

    if (target_sensor == null and this.filter_sensor == null) {
        const preferred_keywords = [_][]const u8{
            "package id",
            "tctl",
            "tdie",
            "coretemp",
            "k10temp",
            "x86_pkg_temp",
            "cpu",
        };

        for (preferred_keywords) |kw| {
            for (this.sensors.items) |sensor| {
                if (containsIgnoreCase(sensor.name, kw)) {
                    target_sensor = sensor;
                    break;
                }
            }
            if (target_sensor != null) break;
        }

        if (target_sensor == null) {
            var highest_idx: usize = 0;
            var highest_temp: f64 = -273.15;
            for (this.sensors.items, 0..) |s, idx| {
                if (s.celsius > highest_temp) {
                    highest_temp = s.celsius;
                    highest_idx = idx;
                }
            }
            target_sensor = this.sensors.items[highest_idx];
        }
    }

    const selected = target_sensor orelse this.sensors.items[0];
    this.info = .{
        .celsius = selected.celsius,
        .fahrenheit = selected.fahrenheit,
        .sensor_name = selected.name,
        .max_celsius = overall_max,
        .crit_celsius = selected.crit_celsius,
    };
}

fn scanHwmon(this: *Temperature, hwmon_dir: Dir) !void {
    var it = hwmon_dir.iterate();
    while (try it.next(this.io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!mem.startsWith(u8, entry.name, "hwmon")) continue;

        var dev_dir = hwmon_dir.openDir(this.io, entry.name, .{ .iterate = true }) catch continue;
        defer dev_dir.close(this.io);

        this.scanDevice(dev_dir) catch continue;
    }
}

fn scanDevice(this: *Temperature, dev_dir: Dir) !void {
    var chip_name_buf: [64]u8 = undefined;
    var chip_name: []const u8 = "hwmon";
    if (dev_dir.openFile(this.io, "name", .{})) |name_file_val| {
        var name_file = name_file_val;
        defer name_file.close(this.io);
        const len = name_file.readStreaming(this.io, &.{chip_name_buf[0..]}) catch 0;
        if (len > 0) {
            chip_name = mem.trim(u8, chip_name_buf[0..len], &ascii.whitespace);
        }
    } else |_| {}

    var it = dev_dir.iterate();
    while (try it.next(this.io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!mem.startsWith(u8, entry.name, "temp") or !mem.endsWith(u8, entry.name, "_input")) continue;

        const milli_celsius = sysfs.readMilli(this.io, dev_dir, entry.name) catch continue;
        const celsius = @as(f64, @floatFromInt(milli_celsius)) / 1000.0;
        if (celsius < -50.0 or celsius > 200.0) continue;

        const fahrenheit = celsius * 9.0 / 5.0 + 32.0;

        const prefix = entry.name[0 .. entry.name.len - "_input".len];

        var crit_buf: [32]u8 = undefined;
        const crit_filename = mem.print(&crit_buf, "{s}_crit", .{prefix}) catch "";
        const crit_celsius: ?f64 = if (sysfs.readMilli(this.io, dev_dir, crit_filename)) |mc|
            @as(f64, @floatFromInt(mc)) / 1000.0
        else |_|
            null;

        var max_buf: [32]u8 = undefined;
        const max_filename = mem.print(&max_buf, "{s}_max", .{prefix}) catch "";
        const max_celsius: ?f64 = if (sysfs.readMilli(this.io, dev_dir, max_filename)) |mc|
            @as(f64, @floatFromInt(mc)) / 1000.0
        else |_|
            null;

        var label_buf: [32]u8 = undefined;
        const label_filename = mem.print(&label_buf, "{s}_label", .{prefix}) catch "";
        var sensor_name: []const u8 = undefined;

        if (dev_dir.openFile(this.io, label_filename, .{})) |lbl_file_val| {
            var lbl_file = lbl_file_val;
            defer lbl_file.close(this.io);
            var lbuf: [64]u8 = undefined;
            const llen = lbl_file.readStreaming(this.io, &.{lbuf[0..]}) catch 0;
            if (llen > 0) {
                const label = mem.trim(u8, lbuf[0..llen], &ascii.whitespace);
                sensor_name = try this.allocator.print("{s} {s}", .{ chip_name, label });
            } else {
                sensor_name = try this.allocator.print("{s} {s}", .{ chip_name, prefix });
            }
        } else |_| {
            sensor_name = try this.allocator.print("{s} {s}", .{ chip_name, prefix });
        }
        errdefer this.allocator.free(sensor_name);

        try this.sensors.append(this.allocator, .{
            .name = sensor_name,
            .celsius = celsius,
            .fahrenheit = fahrenheit,
            .crit_celsius = crit_celsius,
            .max_celsius = max_celsius,
        });
    }
}

fn scanThermal(this: *Temperature, thermal_dir: Dir) !void {
    var it = thermal_dir.iterate();
    while (try it.next(this.io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!mem.startsWith(u8, entry.name, "thermal_zone")) continue;

        var zone_dir = thermal_dir.openDir(this.io, entry.name, .{}) catch continue;
        defer zone_dir.close(this.io);

        const milli_celsius = sysfs.readMilli(this.io, zone_dir, "temp") catch continue;
        const celsius = @as(f64, @floatFromInt(milli_celsius)) / 1000.0;
        if (celsius < -50.0 or celsius > 200.0) continue;

        const fahrenheit = celsius * 9.0 / 5.0 + 32.0;

        var type_buf: [64]u8 = undefined;
        var zone_type: []const u8 = entry.name;
        if (zone_dir.openFile(this.io, "type", .{})) |tf_val| {
            var tf = tf_val;
            defer tf.close(this.io);
            const len = tf.readStreaming(this.io, &.{type_buf[0..]}) catch 0;
            if (len > 0) zone_type = mem.trim(u8, type_buf[0..len], &ascii.whitespace);
        } else |_| {}

        const sensor_name = try this.allocator.dupe(u8, zone_type);
        errdefer this.allocator.free(sensor_name);

        try this.sensors.append(this.allocator, .{
            .name = sensor_name,
            .celsius = celsius,
            .fahrenheit = fahrenheit,
        });
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const testing = std.testing;

test "Temperature hwmon scanner" {
    const Threaded = Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "name", .data = "coretemp\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "temp1_input", .data = "42000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "temp1_label", .data = "Package id 0\n" });
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const path = buf[0..len];

    var dev_dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dev_dir.close(io);

    var temp: Temperature = .init(io, testing.allocator, null);
    defer temp.deinit();

    try temp.scanDevice(dev_dir);
    try testing.expectEqual(@as(usize, 1), temp.sensors.items.len);
    try testing.expectEqual(@as(f64, 42.0), temp.sensors.items[0].celsius);
    try testing.expectEqual(@as(f64, 107.6), temp.sensors.items[0].fahrenheit);
    try testing.expectEqualStrings("coretemp Package id 0", temp.sensors.items[0].name);
}
