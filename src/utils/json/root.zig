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

/// An incremental JSON object builder with explicit memory management.
const Json = @This();

const Field = @import("Field.zig");
const Value = @import("Value.zig").Value;

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const fmt = std.fmt;
const debug = std.debug;
const testing = std.testing;

allocator: Allocator,
fields: ArrayList(Field) = .empty,
counter: u64 = 0,

/// Initializes a new JSON builder using the given allocator.
///
/// The builder takes ownership of all heap-allocated values it creates
/// and will release them when `deinit` is called.
///
/// The returned builder starts with no fields and a reset internal state.
pub inline fn init(allocator: Allocator) Json {
    return .{ .allocator = allocator };
}

/// Frees all resources owned by the JSON builder.
///
/// All heap-allocated string values stored in fields are released.
/// After freeing field values, the internal field list is deinitialized
/// and the line-append counter is reset.
///
/// This function must be called exactly once for every initialized builder
/// to avoid memory leaks.
pub inline fn deinit(self: *Json) void {
    for (self.fields.items) |field| {
        switch (field.value) {
            .string => |s| self.allocator.free(s),
            .array_string => |arr| {
                for (arr) |s| self.allocator.free(s);
                self.allocator.free(arr);
            },
            else => {},
        }
    }

    self.fields.deinit(self.allocator);
    self.counter = 0;
}

/// Clears all fields and resets the builder state for reuse.
///
/// This frees all heap-allocated string values but retains the
/// underlying field list capacity, making it efficient for reuse
/// in scenarios where the builder is used repeatedly.
///
/// After calling `clear()`, the builder can be used again as if
/// freshly initialized, but without reallocating the backing array.
pub inline fn clear(self: *Json) void {
    for (self.fields.items) |field| {
        switch (field.value) {
            .string => |s| self.allocator.free(s),
            .array_string => |arr| {
                for (arr) |s| self.allocator.free(s);
                self.allocator.free(arr);
            },
            else => {},
        }
    }

    self.fields.clearRetainingCapacity();
    self.counter = 0;
}

/// Sets a JSON field with a statically supported value type.
///
/// Supported value types:
/// - `[]const u8`, string literals → JSON string
/// - `[]const []const u8` → JSON array of strings
/// - Integer types (`u8/i8` … `usize/isize`) → JSON number
/// - `bool` → JSON boolean
///
/// Unsupported types cause a compile-time error.
///
/// This function does not perform key deduplication; setting the same key
/// multiple times will result in multiple entries in the output.
pub fn set(self: *Json, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);

    const v: Value = switch (T) {
        bool => .{ .boolean = value },
        u8, i8, u16, i16, u32, i32, u64, i64, usize, isize => .{ .number = @intCast(value) },
        []const []const u8, [][]const u8, [][]u8 => bk: {
            var list = try self.allocator.alloc([]const u8, value.len);
            var count: usize = 0;
            errdefer {
                for (list[0..count]) |elem| self.allocator.free(elem);
                self.allocator.free(list);
            }
            for (value) |elem| {
                list[count] = try self.allocator.dupe(u8, elem);
                count += 1;
            }
            break :bk .{ .array_string = list };
        },
        else => bk: {
            const slice: []const u8 = value;
            const owned_str = try self.allocator.dupe(u8, slice);
            break :bk .{ .string = owned_str };
        },
    };

    try self.fields.append(self.allocator, .{ .key = key, .value = v });
}

/// Sets the Waybar "class" field as a single class name string.
pub fn setClass(self: *Json, class_name: []const u8) !void {
    return self.set("class", class_name);
}

/// Sets the Waybar "class" field as an array of class name strings.
pub fn setClasses(self: *Json, classes: []const []const u8) !void {
    return self.set("class", classes);
}

/// Sets a JSON string field using a formatted string.
///
/// The formatted value is allocated and stored as a string field
/// associated with the given `key`.
///
/// This function does not check for existing keys; if the same key
/// is set multiple times, all entries will be written to the output.
/// Use this intentionally or ensure uniqueness at the call site.
pub fn setFmt(self: *Json, key: []const u8, comptime value: []const u8, args: anytype) !void {
    const str = try fmt.allocPrint(self.allocator, value, args);
    errdefer self.allocator.free(str);

    try self.fields.append(self.allocator, .{ .key = key, .value = .{ .string = str } });
}

/// Checks whether a field with the given key exists.
///
/// Returns `true` if any field in the builder has a matching key,
/// `false` otherwise.
///
/// This is useful for conditionally setting or appending values
/// without duplicating keys unintentionally.
pub fn has(self: *Json, key: []const u8) bool {
    for (self.fields.items) |f| {
        if (mem.eql(u8, f.key, key)) return true;
    }

    return false;
}

/// Appends a formatted string to an existing JSON string field.
///
/// If a field with the given `key` already exists and its value is a string,
/// the formatted output is concatenated to the existing value.
///
/// If the key does not exist, a new string field is created.
///
/// Panics if the key exists but the associated value is not a string,
/// as appending is only valid for string fields.
pub fn appendFmt(self: *Json, key: []const u8, comptime value: []const u8, args: anytype) !void {
    const part = try fmt.allocPrint(self.allocator, value, args);
    errdefer self.allocator.free(part);

    for (self.fields.items) |*f| {
        if (mem.eql(u8, f.key, key)) {
            switch (f.value) {
                .string => |old| {
                    const combined = try mem.concat(self.allocator, u8, &.{ old, part });
                    errdefer self.allocator.free(combined);

                    self.allocator.free(old);
                    self.allocator.free(part);

                    f.value = .{ .string = combined };
                    return;
                },
                else => debug.panic("appendFmt: key '{s}' exists but value '{any}' is not string", .{ f.key, @TypeOf(f.value) }),
            }
        }
    }

    try self.fields.append(self.allocator, .{ .key = key, .value = .{ .string = part } });
}

/// Appends a formatted string to a string field, inserting a newline if needed.
///
/// On the first append, the formatted value is added as-is.
/// On subsequent appends, a leading newline (`\n`) is automatically inserted
/// before the formatted value.
///
/// This is useful for building multi-line JSON string fields such as
/// Waybar tooltips, without having to manually track newline placement.
///
/// The internal `counter` is incremented after each call.
pub fn appendFmtNL(self: *Json, key: []const u8, comptime value: []const u8, args: anytype) !void {
    if (!self.has(key)) try self.set(key, "");

    if (self.counter > 0) {
        try self.appendFmt(key, "\n" ++ value, args);
    } else {
        try self.appendFmt(key, value, args);
    }

    self.counter += 1;
}

/// Writes the JSON object to the given writer.
///
/// All stored fields are written as a single JSON object in insertion order.
/// Keys are written as JSON strings, and values are serialized via `writeValue`.
///
/// The output is compact (no extra whitespace) and ends with a newline,
/// making it suitable for streaming output (e.g. Waybar modules).
pub fn write(self: *Json, writer: *Io.Writer) !void {
    try writer.writeAll("{");

    for (self.fields.items, 0..) |field, i| {
        if (i != 0) try writer.writeAll(",");

        try writer.print("\"{s}\":", .{field.key});
        try writeValue(writer, field.value);
    }

    try writer.writeAll("}");
    try writer.writeByte('\n');
}

/// Writes a JSON value to the given writer.
///
/// Strings are automatically quoted and escaped according to JSON rules.
/// Numbers and booleans are written in their JSON literal form.
///
/// This function does not write any surrounding whitespace.
pub fn writeValue(writer: *Io.Writer, value: Value) !void {
    switch (value) {
        .string => |s| {
            try writer.writeByte('"');
            try writeEscaped(writer, s);
            try writer.writeByte('"');
        },
        .array_string => |arr| {
            try writer.writeByte('[');
            for (arr, 0..) |s, i| {
                if (i != 0) try writer.writeByte(',');
                try writer.writeByte('"');
                try writeEscaped(writer, s);
                try writer.writeByte('"');
            }
            try writer.writeByte(']');
        },
        .number => |n| try writer.print("{d}", .{n}),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
    }
}

/// Writes a string with JSON-escaped characters to the given writer.
///
/// The following characters are escaped:
/// - `"`
/// - `\\`
/// - Newline (`\n`)
/// - Carriage return (`\r`)
/// - Tab (`\t`)
///
/// This function does **not** add surrounding quotes.
/// It is intended to be used internally by `writeValue`.
pub fn writeEscaped(writer: *Io.Writer, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
}

test "Json class and string array serialization" {
    var json_obj: Json = .init(testing.allocator);
    defer json_obj.deinit();

    try json_obj.set("text", "Hello");
    try json_obj.setClass("warning");

    var buf: [256]u8 = undefined;
    var fbs = Io.Writer.fixed(&buf);
    try json_obj.write(&fbs);
    try testing.expectEqualStrings("{\"text\":\"Hello\",\"class\":\"warning\"}\n", fbs.buffered());

    json_obj.clear();
    const classes = [_][]const u8{ "warning", "critical" };
    try json_obj.setClasses(&classes);
    var fbs2 = Io.Writer.fixed(&buf);
    try json_obj.write(&fbs2);
    try testing.expectEqualStrings("{\"class\":[\"warning\",\"critical\"]}\n", fbs2.buffered());
}

test "Json writeEscaped control characters" {
    var buf: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    try writeEscaped(&writer, "hello\nworld\r\"test\"\t\x08\x0c\x01\x1f");
    try testing.expectEqualStrings("hello\\nworld\\r\\\"test\\\"\\t\\b\\f\\u0001\\u001f", writer.buffered());
}
