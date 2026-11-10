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
pub const Template = @import("Template.zig");

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
pub fn deinit(this: *Replacer) void {
    this.freeValues();
    this.values.deinit();
}

/// Frees all owned data and clears internal state while retaining capacity.
pub fn clear(this: *Replacer) void {
    this.freeValues();
    this.values.clearRetainingCapacity();
}

pub fn free(this: *Replacer, memory: anytype) void {
    this.allocator.free(memory);
}

pub inline fn setStrict(this: *Replacer, enabled: bool) void {
    this.strict = enabled;
}

/// Associates `key` with a string value. Both are duplicated internally.
pub fn addKey(this: *Replacer, key: []const u8, value: []const u8) !void {
    const val_owned = try this.allocator.dupe(u8, value);
    errdefer this.free(val_owned);
    try this.putValue(key, .{ .string = val_owned });
}

/// Associates `key` with a typed value inferred from `value`'s comptime type.
pub fn addKeyAny(this: *Replacer, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (info == .int or info == .comptime_int) {
        return this.putValue(key, .{ .integer = @intCast(value) });
    }

    if (info == .float or info == .comptime_float) {
        return this.putValue(key, .{ .float = @floatCast(value) });
    }

    if (T == bool) {
        return this.putValue(key, .{ .boolean = value });
    }

    if (T == []const u8 or T == []u8) {
        return this.addKey(key, value);
    }

    if (info == .pointer and info.pointer.size == .many) {
        return this.addKey(key, mem.span(value));
    }

    const str = try this.allocator.print("{any}", .{value});
    defer this.free(str);
    return this.addKey(key, str);
}

/// Renders `template` into `writer`, substituting `{key}`, `{key:spec}`, and chained sequences.
pub fn renderToWriter(this: *const Replacer, template: []const u8, writer: *Writer) !void {
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];

        if (c != '{') {
            try writer.writeByte(c);
            i += 1;
            continue;
        }

        if (i + 1 < template.len and template[i + 1] == '{') {
            try writer.writeByte('{');
            i += 2;
            continue;
        }

        const rest = template[i + 1 ..];
        const close = mem.findScalar(u8, rest, '}') orelse {
            try writer.writeByte(c);
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

                if (this.values.get(current_key.?)) |_| {
                    first_key_found = true;
                } else {
                    break;
                }
            } else {
                if (isFormatSpec(token)) {
                    current_spec = token;
                } else if (token.len >= 2 and token[0] == '\'' and token[token.len - 1] == '\'') {
                    if (current_key) |k| {
                        if (this.values.get(k)) |val| {
                            try appendValueToWriter(writer, val, current_spec);
                        } else if (this.strict) {
                            return ReplacerError.PlaceholderNotFound;
                        }
                    }
                    try writer.writeAll(token[1 .. token.len - 1]);
                    current_key = null;
                    current_spec = null;
                } else {
                    if (current_key) |k| {
                        if (this.values.get(k)) |val| {
                            try appendValueToWriter(writer, val, current_spec);
                        } else if (this.strict) {
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
                if (this.values.get(k)) |val| {
                    try appendValueToWriter(writer, val, current_spec);
                } else if (this.strict) {
                    return ReplacerError.PlaceholderNotFound;
                }
            }
            i += close + 2;
            continue;
        }

        if (this.strict) return ReplacerError.PlaceholderNotFound;

        try writer.writeAll(template[i .. i + close + 2]);
        i += close + 2;
    }
}

/// Renders `template` directly into a caller-provided fixed buffer (zero heap allocation).
pub fn renderBuf(this: *const Replacer, template: []const u8, out_buf: []u8) ![]const u8 {
    var writer = Writer.fixed(out_buf);
    try this.renderToWriter(template, &writer);
    return writer.buffered();
}

/// Renders `template`, substituting `{key}`, `{key:spec}`, and chained sequences into an allocated string.
pub fn render(this: *const Replacer, template: []const u8) ![]u8 {
    var aw: Writer.Allocating = .init(this.allocator);
    defer aw.deinit();

    try this.renderToWriter(template, &aw.writer);
    return try aw.toOwnedSlice();
}

/// Registers common escape-sequence placeholders available to all modules.
///
/// Placeholders: `{newline}` `{nl}` `{tab}` `{dot}` `{pipe}`
pub fn addCommonPlaceholders(this: *Replacer) !void {
    try this.addKey("newline", "\n");
    try this.addKey("nl", "\n");
    try this.addKey("tab", "\t");
    try this.addKey("dot", "·");
    try this.addKey("pipe", "|");
}

/// Writes `bytes` as a human-readable size string using the given unit system.
pub fn formatBytes(writer: *Writer, bytes: i64, precision: usize, system: Units) !void {
    try scaleAndWrite(writer, @floatFromInt(bytes), precision, system.base(), system.byteUnits());
}

/// Writes `bytes_per_sec` as a human-readable speed string using the given unit system.
pub fn formatSpeed(writer: *Writer, bytes_per_sec: f64, precision: usize, system: Units) !void {
    try scaleAndWrite(writer, bytes_per_sec, precision, system.base(), system.speedUnits());
}

fn freeValues(this: *Replacer) void {
    var it = this.values.iterator();
    while (it.next()) |e| {
        this.free(e.key_ptr.*);
        if (e.value_ptr.* == .string) this.free(e.value_ptr.string);
    }
}

/// Inserts or replaces a value, freeing any previously-owned string.
fn putValue(this: *Replacer, key: []const u8, value: Value) !void {
    const gop = try this.values.getOrPut(key);

    if (gop.found_existing) {
        if (gop.value_ptr.* == .string) this.free(gop.value_ptr.string);
        gop.value_ptr.* = value;
        return;
    }

    gop.key_ptr.* = this.allocator.dupe(u8, key) catch |err| {
        _ = this.values.remove(key);
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

/// Appends the formatted representation of `val` to `writer`.
pub fn appendValueToWriter(writer: *Writer, val: Value, spec: ?[]const u8) !void {
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

test "Replacer renderBuf zero-alloc" {
    var replacer: Replacer = .init(testing.allocator);
    defer replacer.deinit();

    try replacer.addKey("user", "antigravity");
    try replacer.addKeyAny("score", @as(i64, 99));

    var buf: [128]u8 = undefined;
    const res = try replacer.renderBuf("User: {user}, Score: {score}%", &buf);
    try testing.expectEqualStrings("User: antigravity, Score: 99%", res);
}

test "Template compile and renderBuf" {
    var tmpl: Template = try .compile(testing.allocator, "{icon}  {val}% [{status}]");
    defer tmpl.deinit();

    var replacer: Replacer = .init(testing.allocator);
    defer replacer.deinit();

    try replacer.addKey("icon", "⚡");
    try replacer.addKeyAny("val", @as(i64, 85));
    try replacer.addKey("status", "Charging");

    var buf: [128]u8 = undefined;
    const out = try tmpl.renderBuf(&replacer, &buf);
    try testing.expectEqualStrings("⚡  85% [Charging]", out);
}
