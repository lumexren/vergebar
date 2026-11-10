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
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Retrieve an environment variable value by key (stateless, zero-allocation).
pub fn get(key: []const u8) ?[:0]const u8 {
    if (builtin.link_libc) {
        var key_buf: [256]u8 = undefined;
        if (key.len >= key_buf.len) return null;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;

        if (std.c.getenv(key_buf[0..key.len :0])) |val| {
            return mem.span(val);
        }
        return null;
    } else {
        return null;
    }
}

/// Check if an environment variable exists and is non-empty.
pub fn has(key: []const u8) bool {
    const val = get(key) orelse return false;
    return val.len > 0;
}

/// Retrieve the current user's home directory.
pub fn getHome() ?[:0]const u8 {
    return get("HOME");
}

/// Retrieve the XDG runtime directory (defaults to `/run/user/1000` if unset).
pub fn getRuntimeDir() []const u8 {
    return get("XDG_RUNTIME_DIR") orelse "/run/user/1000";
}

/// Retrieve the raw $XDG_CONFIG_HOME environment variable, if set and non-empty.
pub fn getXdgConfigHome() ?[:0]const u8 {
    const val = get("XDG_CONFIG_HOME") orelse return null;
    return if (val.len > 0) val else null;
}

/// Check if $XDG_CONFIG_HOME is set and non-empty.
pub fn hasXdgConfigHome() bool {
    return getXdgConfigHome() != null;
}

/// Retrieve the user's config directory ($XDG_CONFIG_HOME or fallback to $HOME/.config).
pub fn getConfigHome(allocator: Allocator) ?[]const u8 {
    if (getXdgConfigHome()) |dir| {
        return allocator.dupe(u8, dir) catch null;
    }
    if (getHome()) |home| {
        if (home.len > 0) {
            return allocator.print("{s}/.config", .{home}) catch null;
        }
    }
    return null;
}

/// Retrieve the user's config directory ($XDG_CONFIG_HOME or fallback to $HOME/.config) into a caller buffer.
pub fn getConfigHomeBuf(out_buf: []u8) ?[]const u8 {
    if (getXdgConfigHome()) |dir| {
        if (dir.len <= out_buf.len) {
            @memcpy(out_buf[0..dir.len], dir);
            return out_buf[0..dir.len];
        }
    }
    if (getHome()) |home| {
        if (home.len > 0) {
            const suffix = "/.config";
            const total = home.len + suffix.len;
            if (total <= out_buf.len) {
                @memcpy(out_buf[0..home.len], home);
                @memcpy(out_buf[home.len..total], suffix);
                return out_buf[0..total];
            }
        }
    }
    return null;
}

/// Resolve a configuration subpath relative to $XDG_CONFIG_HOME (or fallback $HOME/.config) with heap allocation.
pub fn resolveConfigPathAlloc(allocator: Allocator, subpath: []const u8) !?[]const u8 {
    const trimmed = mem.trimEnd(u8, subpath, "/");
    if (getXdgConfigHome()) |dir| {
        return try allocator.print("{s}/{s}", .{ dir, trimmed });
    }
    if (getHome()) |home| {
        if (home.len > 0) {
            return try allocator.print("{s}/.config/{s}", .{ home, trimmed });
        }
    }
    return null;
}

/// Resolve a configuration subpath relative to $XDG_CONFIG_HOME (or fallback $HOME/.config) into a caller buffer.
pub fn resolveConfigPathBuf(subpath: []const u8, out_buf: []u8) ?[]const u8 {
    const base = getConfigHomeBuf(out_buf) orelse return null;
    const base_len = base.len;
    const trimmed = mem.trimEnd(u8, subpath, "/");
    const total = base_len + 1 + trimmed.len;
    if (total <= out_buf.len) {
        out_buf[base_len] = '/';
        @memcpy(out_buf[base_len + 1 .. total], trimmed);
        return out_buf[0..total];
    }
    return null;
}

/// Expand leading `~/` with user's home directory into a caller-provided buffer.
pub fn expandHomeBuf(path: []const u8, out_buf: []u8) []const u8 {
    if (mem.startsWith(u8, path, "~/")) {
        if (getHome()) |home| {
            const sub = path[2..];
            const total = home.len + 1 + sub.len;
            if (total <= out_buf.len) {
                @memcpy(out_buf[0..home.len], home);
                out_buf[home.len] = '/';
                @memcpy(out_buf[home.len + 1 .. total], sub);
                return out_buf[0..total];
            }
        }
    }
    return path;
}

/// Expand leading `~/` with user's home directory, allocating on the heap.
pub fn expandHomeAlloc(allocator: Allocator, path: []const u8) ![]const u8 {
    if (mem.startsWith(u8, path, "~/")) {
        if (getHome()) |home| {
            return try allocator.print("{s}/{s}", .{ home, path[2..] });
        }
    }
    return try allocator.dupe(u8, path);
}

test "env utility functions" {
    const testing = std.testing;

    try testing.expect(get("PATH") != null);
    try testing.expect(has("PATH"));
    try testing.expect(get("NON_EXISTENT_VAR_12345XYZ") == null);
    try testing.expect(!has("NON_EXISTENT_VAR_12345XYZ"));

    var buf: [256]u8 = undefined;
    const expanded = expandHomeBuf("foo/bar", &buf);
    try testing.expectEqualStrings("foo/bar", expanded);
}
