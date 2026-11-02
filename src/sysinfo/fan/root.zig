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

const Fan = @This();

pub const FanInfo = @import("FanInfo.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const debug = std.debug;

pub const HWMON_PATH = "/sys/class/hwmon";

io: Io,
allocator: Allocator,
fans: *ArrayList(FanInfo),

pub inline fn init(io: Io, allocator: Allocator, fans: *ArrayList(FanInfo)) Fan {
    return .{
        .io = io,
        .allocator = allocator,
        .fans = fans,
    };
}

pub fn deinit(self: Fan) void {
    for (self.fans.items) |f| self.allocator.free(f.name);
    self.fans.deinit(self.allocator);
}

pub fn clear(self: Fan) void {
    self.fans.clearRetainingCapacity();
}

pub fn scan(self: Fan) !void {
    var hwmon_dir = try Dir.openDirAbsolute(self.io, HWMON_PATH, .{ .iterate = true });
    defer hwmon_dir.close(self.io);

    try self.scanHwmon(hwmon_dir);
}

pub fn scanHwmon(self: Fan, hwmon_dir: Dir) !void {
    var it = hwmon_dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!mem.startsWith(u8, entry.name, "hwmon")) continue;

        var device_dir = try hwmon_dir.openDir(self.io, entry.name, .{ .iterate = true });
        defer device_dir.close(self.io);

        try self.scanDevice(device_dir);
    }
}

pub fn scanDevice(self: Fan, device_dir: Dir) !void {
    var it = device_dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!mem.startsWith(u8, entry.name, "fan") or !mem.endsWith(u8, entry.name, "_input")) continue;

        const speed = readFanSpeed(self.io, device_dir, entry.name) catch continue;
        if (speed <= 0) continue;

        const name = try readFanName(self.io, self.allocator, device_dir, entry.name);
        errdefer self.allocator.free(name);

        try self.fans.append(self.allocator, .{ .name = name, .speed = speed });
    }
}

fn readFanSpeed(io: Io, device_dir: Dir, input_name: []const u8) !i64 {
    var file = try device_dir.openFile(io, input_name, .{});
    defer file.close(io);

    var buf: [32]u8 = undefined;
    const len = try file.readStreaming(io, &.{buf[0..]});

    const trimmed = mem.trim(u8, buf[0..len], &ascii.whitespace);
    return fmt.parseInt(i64, trimmed, 10);
}

fn readFanName(io: Io, allocator: Allocator, device_dir: Dir, input_name: []const u8) ![]const u8 {
    if (mem.endsWith(u8, input_name, "_input")) {
        const base = input_name[0 .. input_name.len - 6];

        var label_buf: [64]u8 = undefined;
        const label_name = mem.print(&label_buf, "{s}_label", .{base}) catch unreachable;

        if (device_dir.openFile(io, label_name, .{})) |label_file| {
            defer label_file.close(io);

            var buf: [64]u8 = undefined;
            const len = label_file.readStreaming(io, &.{buf[0..]}) catch 0;
            if (len > 0) return allocator.dupe(u8, mem.trim(u8, buf[0..len], &ascii.whitespace));
        } else |_| {}
    }

    if (device_dir.openFile(io, "name", .{})) |name_file| {
        defer name_file.close(io);

        var buf: [64]u8 = undefined;
        const len = name_file.readStreaming(io, &.{buf[0..]}) catch 0;

        if (len > 0) {
            const dev_name = mem.trim(u8, buf[0..len], &ascii.whitespace);
            const fan_id = input_name[0 .. input_name.len - 6];
            return allocator.print("{s} {s}", .{ dev_name, fan_id });
        }
    } else |_| {}

    return allocator.dupe(u8, input_name);
}

test "scanDeviceFans reproduction" {
    const allocator = testing.allocator;
    const Threaded = Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "fan1_input", .data = "2000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fan1_label", .data = "System Fan\n" });

    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const path = buf[0..len];

    var device_dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer device_dir.close(io);

    var fan_list: ArrayList(FanInfo) = .empty;

    const fan: Fan = .init(io, allocator, &fan_list);
    defer fan.deinit();

    try fan.scanDevice(device_dir);

    try testing.expectEqual(@as(usize, 1), fan.fans.items.len);
    try testing.expectEqualStrings("System Fan", fan.fans.items[0].name);
    try testing.expectEqual(@as(i64, 2000), fan.fans.items[0].speed);
}

test "scanDeviceFans fallback" {
    const allocator = testing.allocator;
    const Threaded = Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "fan2_input", .data = "1500\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "name", .data = "k10temp\n" });

    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const path = buf[0..len];

    var device_dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer device_dir.close(io);

    var fan_list: ArrayList(FanInfo) = .empty;

    const fan: Fan = .init(io, allocator, &fan_list);
    defer fan.deinit();

    try fan.scanDevice(device_dir);

    try testing.expectEqualStrings("k10temp fan2", fan.fans.items[0].name);
    try testing.expectEqual(@as(i64, 1500), fan.fans.items[0].speed);
}

test "scanHwmonFans" {
    const allocator = testing.allocator;
    const Threaded = Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "hwmon0", .default_dir);
    try tmp.dir.createDir(io, "hwmon1", .default_dir);
    try tmp.dir.createDir(io, "other", .default_dir);

    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon0/fan1_input", .data = "1000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon0/fan1_label", .data = "CPU Fan\n" });

    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon1/fan1_input", .data = "2000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon1/name", .data = "box\n" });

    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const path = buf[0..len];

    var hwmon_dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer hwmon_dir.close(io);

    var fan_list: ArrayList(FanInfo) = .empty;

    const fan: Fan = .init(io, allocator, &fan_list);
    defer fan.deinit();

    try fan.scanHwmon(hwmon_dir);

    try testing.expectEqual(@as(usize, 2), fan.fans.items.len);

    var found_cpu = false;
    var found_box = false;

    for (fan.fans.items) |f| {
        if (mem.eql(u8, f.name, "CPU Fan")) {
            try testing.expectEqual(@as(i64, 1000), f.speed);
            found_cpu = true;
        } else if (mem.eql(u8, f.name, "box fan1")) {
            try testing.expectEqual(@as(i64, 2000), f.speed);
            found_box = true;
        } else {
            debug.print("Found unexpected fan: {s}\n", .{f.name});
        }
    }

    try testing.expect(found_cpu);
    try testing.expect(found_box);
}
