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

/// Applies typed value substitution and byte-sequence replacements to templates.
const Replacer = @This();

const Units = @import("Units.zig").Units;
const Value = @import("Value.zig").Value;
const ReplacerError = @import("ReplacerError.zig").ReplacerError;

const std = @import("std");
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Io = std.Io;
const Writer = Io.Writer;
const fmt = std.fmt;
const ascii = std.ascii;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

allocator: Allocator,
values: StringHashMap(Value),
/// When true, render() returns PlaceholderNotFound for any unresolved key.
/// When false (default), unresolved placeholders are passed through unchanged.
strict: bool = false,

pub fn init(allocator: Allocator) Replacer {
    return .{ .allocator = allocator, .values = .init(allocator) };
}

/// Releases all owned memory. Must be called exactly once when done.
pub fn deinit(self: *Replacer) void {
    self.freeValues();
    self.values.deinit();
}

/// Frees all owned data and clears internal state while retaining capacity.
pub fn clear(self: *Replacer) void {
    self.freeValues();
    self.values.clearRetainingCapacity();
}

pub fn free(self: *Replacer, memory: anytype) void {
    self.allocator.free(memory);
}

pub inline fn setStrict(self: *Replacer, enabled: bool) void {
    self.strict = enabled;
}

/// Associates `key` with a string value. Both are duplicated internally.
pub fn addKey(self: *Replacer, key: []const u8, value: []const u8) !void {
    const val_owned = try self.allocator.dupe(u8, value);
    errdefer self.free(val_owned);
    try self.putValue(key, .{ .string = val_owned });
}

/// Associates `key` with a typed value inferred from `value`'s comptime type.
pub fn addKeyAny(self: *Replacer, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (info == .int or info == .comptime_int) {
        return self.putValue(key, .{ .integer = @intCast(value) });
    }

    if (info == .float or info == .comptime_float) {
        return self.putValue(key, .{ .float = @floatCast(value) });
    }

    if (T == bool) {
        return self.putValue(key, .{ .boolean = value });
    }

    if (T == []const u8 or T == []u8) {
        return self.addKey(key, value);
    }

    if (info == .pointer and info.pointer.size == .many) {
        return self.addKey(key, mem.span(value));
    }

    const str = try fmt.allocPrint(self.allocator, "{any}", .{value});
    defer self.free(str);
    return self.addKey(key, str);
}

/// Renders `template` into `writer`, substituting `{key}`, `{key:spec}`, and chained sequences.
///
/// Format specifiers:
///   - `{key:.N}` — integer formatted as bytes with N decimal places (binary units)
///   - `{key:^N}` — float formatted as transfer speed with N decimal places (decimal units)
///   - `{key*N}`  — string repeated N times
///   - `{key:N}`  — zero-padded integer (width N) or rounded float (N decimal places)
///
/// Variable Chaining & Literals:
///   - `{key:anotherkey:yet_another}` — evaluates and joins multiple global placeholders sequentially.
///   - `{key:spec:'string_literal'}` — appends a literal raw string immediately after evaluation.
pub fn render(self: *const Replacer, template: []const u8) ![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(self.allocator);

    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];

        if (c != '{') {
            try result.append(self.allocator, c);
            i += 1;
            continue;
        }

        if (i + 1 < template.len and template[i + 1] == '{') {
            try result.append(self.allocator, '{');
            i += 2;
            continue;
        }

        const rest = template[i + 1 ..];
        const close = mem.findScalar(u8, rest, '}') orelse {
            try result.append(self.allocator, c);
            i += 1;
            continue;
        };

        const content = rest[0..close];

        var parts = mem.splitScalar(u8, content, ':');
        var current_key: ?[]const u8 = null;
        var current_spec: ?[]const u8 = null;
        var is_first = true;
        var first_key_found = false;

        while (parts.next()) |token| {
            if (is_first) {
                current_key = token;
                is_first = false;

                if (mem.findScalar(u8, token, '*')) |star| {
                    if (star > 0) {
                        current_key = token[0..star];
                        current_spec = token[star..];
                    }
                }

                if (self.values.get(current_key.?)) |_| {
                    first_key_found = true;
                } else {
                    break;
                }
            } else {
                if (isFormatSpec(token)) {
                    current_spec = token;
                } else if (token.len >= 2 and token[0] == '\'' and token[token.len - 1] == '\'') {
                    if (current_key) |k| {
                        if (self.values.get(k)) |val| {
                            try appendValue(self.allocator, &result, val, current_spec);
                        } else if (self.strict) {
                            return ReplacerError.PlaceholderNotFound;
                        }
                    }
                    try result.appendSlice(self.allocator, token[1 .. token.len - 1]);
                    current_key = null;
                    current_spec = null;
                } else {
                    if (current_key) |k| {
                        if (self.values.get(k)) |val| {
                            try appendValue(self.allocator, &result, val, current_spec);
                        } else if (self.strict) {
                            return ReplacerError.PlaceholderNotFound;
                        }
                    }
                    current_key = token;
                    current_spec = null;
                }
            }
        }

        if (first_key_found) {
            if (current_key) |k| {
                if (self.values.get(k)) |val| {
                    try appendValue(self.allocator, &result, val, current_spec);
                } else if (self.strict) {
                    return ReplacerError.PlaceholderNotFound;
                }
            }
            i += close + 2;
            continue;
        }

        if (self.strict) return ReplacerError.PlaceholderNotFound;

        try result.appendSlice(self.allocator, template[i .. i + close + 2]);
        i += close + 2;
    }

    return try result.toOwnedSlice(self.allocator);
}

/// Registers common escape-sequence placeholders available to all modules.
///
/// Placeholders: `{newline}` `{nl}` `{tab}` `{dot}` `{pipe}`
pub fn addCommonPlaceholders(self: *Replacer) !void {
    try self.addKey("newline", "\n");
    try self.addKey("nl", "\n");
    try self.addKey("tab", "\t");
    try self.addKey("dot", "·");
    try self.addKey("pipe", "|");
}

/// Writes `bytes` as a human-readable size string using the given unit system.
pub fn formatBytes(writer: *Writer, bytes: i64, precision: usize, system: Units) !void {
    try scaleAndWrite(writer, @floatFromInt(bytes), precision, system.base(), system.byteUnits());
}

/// Writes `bytes_per_sec` as a human-readable speed string using the given unit system.
pub fn formatSpeed(writer: *Writer, bytes_per_sec: f64, precision: usize, system: Units) !void {
    try scaleAndWrite(writer, bytes_per_sec, precision, system.base(), system.speedUnits());
}

fn freeValues(self: *Replacer) void {
    var it = self.values.iterator();
    while (it.next()) |e| {
        self.free(e.key_ptr.*);
        if (e.value_ptr.* == .string) self.free(e.value_ptr.string);
    }
}

/// Inserts or replaces a value, freeing any previously-owned string.
fn putValue(self: *Replacer, key: []const u8, value: Value) !void {
    const gop = try self.values.getOrPut(key);

    if (gop.found_existing) {
        if (gop.value_ptr.* == .string) self.free(gop.value_ptr.string);
        gop.value_ptr.* = value;
        return;
    }

    gop.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
        _ = self.values.remove(key);
        return err;
    };

    gop.value_ptr.* = value;
}

/// Returns true if `s` matches a known format-spec token (`.N`, `^N`, `*N`, or a bare width `N`).
fn isFormatSpec(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '.' or s[0] == '^' or s[0] == '*') return true;

    for (s) |c| {
        if (!ascii.isDigit(c)) return false;
    }

    return true;
}

/// Scales `value` down through `units` by repeatedly dividing by `base`,
/// then writes the result with the appropriate suffix.
fn scaleAndWrite(writer: *Writer, value: f64, precision: usize, base: f64, units: []const []const u8) !void {
    const negative = value < 0;
    var size: f64 = @abs(value);
    var idx: usize = 0;

    while (size >= base and idx < units.len - 1) {
        size /= base;
        idx += 1;
    }

    if (negative) size = -size;

    const rounded = roundTo(size, precision);

    if (@trunc(rounded) == rounded) {
        try writer.print("{d}{s}", .{ @as(i64, @intFromFloat(rounded)), units[idx] });
    } else {
        try writer.print("{d:.[1]}", .{ size, precision });
        try writer.writeAll(units[idx]);
    }
}

/// Rounds `v` to `precision` decimal places.
inline fn roundTo(v: f64, precision: usize) f64 {
    const m = math.pow(f64, 10.0, @floatFromInt(precision));
    return @round(v * m) / m;
}

/// Appends the formatted representation of `val` to `buffer`.
fn appendValue(allocator: Allocator, buffer: *ArrayList(u8), val: Value, spec: ?[]const u8) !void {
    var aw: Writer.Allocating = .fromArrayList(allocator, buffer);
    defer buffer.* = aw.toArrayList();

    const writer = &aw.writer;

    switch (val) {
        .string => |s| try appendString(writer, s, spec),
        .integer => |d| try appendInteger(writer, d, spec),
        .float => |f| try appendFloat(writer, f, spec),
        .boolean => |b| try writer.print("{}", .{b}),
    }
}

fn appendString(writer: *Writer, s: []const u8, spec: ?[]const u8) !void {
    const sp = spec orelse return writer.writeAll(s);

    if (sp.len > 0 and sp[0] == '*') {
        const count = fmt.parseInt(usize, sp[1..], 10) catch 1;
        for (0..count) |_| try writer.writeAll(s);
        return;
    }

    try writer.writeAll(s);
}

fn appendInteger(writer: *Writer, d: i64, spec: ?[]const u8) !void {
    const sp = spec orelse return writer.print("{d}", .{d});

    if (sp.len > 0 and sp[0] == '.') {
        const precision = fmt.parseInt(usize, sp[1..], 10) catch 2;
        return formatBytes(writer, d, precision, .binary);
    }

    if (fmt.parseInt(usize, sp, 10)) |width| {
        if (d >= 0) {
            return writer.print("{d:0>[1]}", .{ @as(u64, @intCast(d)), width });
        }

        return writer.print("{d:0>[1]}", .{ d, width });
    } else |_| {}

    try writer.print("{d}", .{d});
}

fn appendFloat(writer: *Writer, f: f64, spec: ?[]const u8) !void {
    const sp = spec orelse return writer.print("{d}", .{f});

    if (sp.len > 0 and sp[0] == '^') {
        const precision = fmt.parseInt(usize, sp[1..], 10) catch 1;
        return formatSpeed(writer, f, precision, .decimal);
    }

    if (fmt.parseInt(usize, sp, 10)) |precision| {
        const rounded = roundTo(f, precision);
        if (@trunc(rounded) == rounded) {
            return writer.print("{d}", .{@as(i64, @intFromFloat(rounded))});
        }

        return writer.print("{d:.[1]}", .{ f, precision });
    } else |_| {}

    try writer.print("{d}", .{f});
}

test "Replacer basic and unresolved placeholder passthrough" {
    var replacer: Replacer = .init(testing.allocator);
    defer replacer.deinit();

    try replacer.addKey("name", "Waybar");
    try replacer.addKeyAny("count", @as(i64, 42));

    const rendered = try replacer.render("Hello {name}! Unresolved: {foo} Count: {count}");
    defer replacer.free(rendered);

    try testing.expectEqualStrings("Hello Waybar! Unresolved: {foo} Count: 42", rendered);
}

test "Replacer strict mode fails on unresolved placeholder" {
    var replacer: Replacer = .init(testing.allocator);
    defer replacer.deinit();
    replacer.setStrict(true);

    try replacer.addKey("name", "Waybar");

    try testing.expectError(ReplacerError.PlaceholderNotFound, replacer.render("Hello {unknown}"));
}
