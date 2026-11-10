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

const Template = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Writer = Io.Writer;

const Replacer = @import("root.zig");
const ReplacerError = @import("ReplacerError.zig").ReplacerError;

pub const Token = union(enum) {
    literal: []const u8,
    placeholder: struct {
        key: []const u8,
        spec: ?[]const u8,
    },
};

allocator: Allocator,
tokens: []Token,
storage: []const u8,

/// Compiles a format string into pre-parsed tokens for zero-allocation rendering.
pub fn compile(allocator: Allocator, template_str: []const u8) !Template {
    const owned = try allocator.dupe(u8, template_str);
    errdefer allocator.free(owned);

    var list: ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);

    var i: usize = 0;
    var start: usize = 0;
    while (i < owned.len) {
        if (owned[i] == '{') {
            if (i + 1 < owned.len and owned[i + 1] == '{') {
                if (i > start) {
                    try list.append(allocator, .{ .literal = owned[start..i] });
                }
                try list.append(allocator, .{ .literal = owned[i .. i + 1] });
                i += 2;
                start = i;
                continue;
            }

            if (mem.findScalar(u8, owned[i + 1 ..], '}')) |close_rel| {
                if (i > start) {
                    try list.append(allocator, .{ .literal = owned[start..i] });
                }
                const content = owned[i + 1 .. i + 1 + close_rel];
                if (mem.findScalar(u8, content, ':')) |colon| {
                    try list.append(allocator, .{
                        .placeholder = .{
                            .key = content[0..colon],
                            .spec = content[colon + 1 ..],
                        },
                    });
                } else if (mem.findScalar(u8, content, '*')) |star| {
                    try list.append(allocator, .{
                        .placeholder = .{
                            .key = content[0..star],
                            .spec = content[star..],
                        },
                    });
                } else {
                    try list.append(allocator, .{
                        .placeholder = .{
                            .key = content,
                            .spec = null,
                        },
                    });
                }
                i = i + 1 + close_rel + 1;
                start = i;
                continue;
            }
        }
        i += 1;
    }

    if (start < owned.len) {
        try list.append(allocator, .{ .literal = owned[start..] });
    }

    return .{
        .allocator = allocator,
        .tokens = try list.toOwnedSlice(allocator),
        .storage = owned,
    };
}

/// Releases the token slice and backing string storage.
pub fn deinit(this: *Template) void {
    this.allocator.free(this.tokens);
    this.allocator.free(this.storage);
    this.* = undefined;
}

/// Evaluates placeholders against `replacer` and streams the rendered output to `writer`.
pub fn renderToWriter(this: *const Template, replacer: *const Replacer, writer: *Writer) !void {
    for (this.tokens) |tok| {
        switch (tok) {
            .literal => |lit| try writer.writeAll(lit),
            .placeholder => |ph| {
                if (replacer.values.get(ph.key)) |val| {
                    try Replacer.appendValueToWriter(writer, val, ph.spec);
                } else if (replacer.strict) {
                    return ReplacerError.PlaceholderNotFound;
                } else {
                    try writer.print("{{{s}", .{ph.key});
                    if (ph.spec) |sp| try writer.print(":{s}", .{sp});
                    try writer.writeAll("}");
                }
            },
        }
    }
}

/// Renders the compiled template directly into caller-provided memory with zero heap allocations.
pub fn renderBuf(this: *const Template, replacer: *const Replacer, out_buf: []u8) ![]const u8 {
    var writer: Writer = .fixed(out_buf);
    try this.renderToWriter(replacer, &writer);
    return writer.buffered();
}

/// Renders the compiled template into a newly allocated slice owned by caller.
pub fn render(this: *const Template, replacer: *const Replacer, allocator: Allocator) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try this.renderToWriter(replacer, &aw.writer);
    return try aw.toOwnedSlice();
}

const testing = std.testing;

test "Template compile and renderBuf" {
    var tmpl = try compile(testing.allocator, "{icon}  {val}% [{status}]");
    defer tmpl.deinit();

    var replacer: Replacer = .init(testing.allocator);
    defer replacer.deinit();

    try replacer.addKey("icon", "⚡");
    try replacer.addKeyAny("val", @as(i64, 85));
    try replacer.addKey("status", "Charging");

    var buf: [128]u8 = undefined;
    const out = try tmpl.renderBuf(&replacer, &buf);
    try testing.expectEqualStrings("⚡  85% [Charging]", out);

    const alloc_out = try tmpl.render(&replacer, testing.allocator);
    defer testing.allocator.free(alloc_out);
    try testing.expectEqualStrings("⚡  85% [Charging]", alloc_out);
}
