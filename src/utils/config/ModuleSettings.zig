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

const ModuleSettings = @This();

const std = @import("std");
const mem = std.mem;
const json = std.json;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;

arena: *ArenaAllocator,
value: json.Value,

pub fn getString(this: ModuleSettings, key: []const u8) ?[]const u8 {
    if (this.value != .object) return null;
    if (this.value.object.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

pub fn getStringOr(this: ModuleSettings, key: []const u8, default_val: []const u8) []const u8 {
    return this.getString(key) orelse default_val;
}

pub fn getInt(this: ModuleSettings, key: []const u8) ?i64 {
    if (this.value != .object) return null;
    if (this.value.object.get(key)) |val| {
        if (val == .integer) return val.integer;
        if (val == .float) return @intFromFloat(val.float);
    }
    return null;
}

pub fn getIntOr(this: ModuleSettings, comptime T: type, key: []const u8, default_val: T) T {
    if (this.getInt(key)) |val| {
        return @intCast(val);
    }
    return default_val;
}

pub fn getFloat(this: ModuleSettings, key: []const u8) ?f64 {
    if (this.value != .object) return null;
    if (this.value.object.get(key)) |val| {
        if (val == .float) return val.float;
        if (val == .integer) return @floatFromInt(val.integer);
    }
    return null;
}

pub fn getFloatOr(this: ModuleSettings, comptime T: type, key: []const u8, default_val: T) T {
    if (this.getFloat(key)) |val| {
        return @floatCast(val);
    }
    return default_val;
}

pub fn getBool(this: ModuleSettings, key: []const u8) ?bool {
    if (this.value != .object) return null;
    if (this.value.object.get(key)) |val| {
        if (val == .bool) return val.bool;
    }
    return null;
}

pub fn getBoolOr(this: ModuleSettings, key: []const u8, default_val: bool) bool {
    return this.getBool(key) orelse default_val;
}

/// Generic strongly-typed getter with default fallback.
pub fn getOr(this: ModuleSettings, comptime T: type, key: []const u8, default_val: T) T {
    return switch (@typeInfo(T)) {
        .bool => this.getBoolOr(key, default_val),
        .int => this.getIntOr(T, key, default_val),
        .float => this.getFloatOr(T, key, default_val),
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8)
            this.getStringOr(key, default_val)
        else
            @compileError("Unsupported pointer type for getOr: " ++ @typeName(T)),
        else => @compileError("Unsupported type for getOr: " ++ @typeName(T)),
    };
}

test "ModuleSettings getOr typed helpers" {
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var map: std.json.ObjectMap = .empty;
    try map.put(arena.allocator(), "interval", .{ .integer = 15 });
    try map.put(arena.allocator(), "format", .{ .string = "{icon} {cpu}%" });
    try map.put(arena.allocator(), "threshold", .{ .float = 85.5 });
    try map.put(arena.allocator(), "enabled", .{ .bool = true });

    const settings: ModuleSettings = .{
        .arena = &arena,
        .value = .{ .object = map },
    };

    try std.testing.expectEqual(@as(u32, 15), settings.getOr(u32, "interval", 2));
    try std.testing.expectEqualStrings("{icon} {cpu}%", settings.getOr([]const u8, "format", "default"));
    try std.testing.expectEqual(@as(f64, 85.5), settings.getOr(f64, "threshold", 50.0));
    try std.testing.expectEqual(true, settings.getOr(bool, "enabled", false));

    // Fallbacks
    try std.testing.expectEqual(@as(u32, 42), settings.getOr(u32, "nonexistent", 42));
    try std.testing.expectEqualStrings("fallback", settings.getOr([]const u8, "nonexistent", "fallback"));
}
