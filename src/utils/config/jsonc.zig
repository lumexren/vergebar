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

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const ascii = std.ascii;
const json = std.json;
const testing = std.testing;

/// Cleans JSONC into valid JSON by:
/// 1. Stripping line comments (// ...)
/// 2. Stripping block comments (/* ... */)
/// 3. Removing trailing commas before } or ]
pub fn cleanJsonc(allocator: Allocator, input: []const u8) ![]u8 {
    var out: ArrayList(u8) = try .initCapacity(allocator, input.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var in_string = false;
    var escape = false;

    while (i < input.len) {
        const c = input[i];

        if (in_string) {
            try out.append(allocator, c);
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            i += 1;
            continue;
        }

        if (c == '"') {
            in_string = true;
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        if (c == '/' and i + 1 < input.len and input[i + 1] == '/') {
            i += 2;
            while (i < input.len and input[i] != '\n') : (i += 1) {}
            continue;
        }

        if (c == '/' and i + 1 < input.len and input[i + 1] == '*') {
            i += 2;
            while (i + 1 < input.len and !(input[i] == '*' and input[i + 1] == '/')) : (i += 1) {}
            if (i + 1 < input.len) i += 2;
            continue;
        }

        try out.append(allocator, c);
        i += 1;
    }

    const cleaned = out.items;
    var j: usize = 0;
    in_string = false;
    escape = false;

    var result: ArrayList(u8) = try .initCapacity(allocator, cleaned.len);
    errdefer result.deinit(allocator);

    while (j < cleaned.len) {
        const c = cleaned[j];
        if (in_string) {
            try result.append(allocator, c);
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            j += 1;
            continue;
        }

        if (c == '"') {
            in_string = true;
            try result.append(allocator, c);
            j += 1;
            continue;
        }

        if (c == ',') {
            var k = j + 1;
            while (k < cleaned.len and ascii.isWhitespace(cleaned[k])) : (k += 1) {}
            if (k < cleaned.len and (cleaned[k] == '}' or cleaned[k] == ']')) {
                j += 1;
                continue;
            }
        }

        try result.append(allocator, c);
        j += 1;
    }

    out.deinit(allocator);
    return result.toOwnedSlice(allocator);
}

test "cleanJsonc removes comments and trailing commas" {
    const allocator = testing.allocator;

    const input =
        \\{
        \\  // line comment
        \\  "test": 123, /* block comment */
        \\  "arr": [1, 2, ],
        \\}
    ;

    const cleaned = try cleanJsonc(allocator, input);
    defer allocator.free(cleaned);

    const parsed = try json.parseFromSlice(json.Value, allocator, cleaned, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.object.contains("test"));
}
