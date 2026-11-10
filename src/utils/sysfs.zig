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
const Io = std.Io;
const Dir = Io.Dir;

/// Check if a file or directory exists at the given absolute or relative path.
pub fn fileExists(io: Io, file_path: []const u8) bool {
    if (Dir.path.isAbsolute(file_path)) {
        Dir.accessAbsolute(io, file_path, .{}) catch return false;
    } else {
        Dir.access(.cwd(), io, file_path, .{}) catch return false;
    }
    return true;
}

/// Read an entire file into a heap-allocated buffer.
pub fn readFileAlloc(io: Io, allocator: Allocator, file_path: []const u8) ![]u8 {
    var file = if (Dir.path.isAbsolute(file_path))
        try Dir.openFileAbsolute(io, file_path, .{ .mode = .read_only })
    else
        try Dir.openFile(.cwd(), io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var io_buf: [4096]u8 = undefined;
    var r = file.reader(io, &io_buf);
    return try r.interface.allocRemaining(allocator, .unlimited);
}

/// Read the first line of a sysfs/procfs attribute into `buf`.
/// Trims leading and trailing whitespace/newlines.
pub fn readLine(io: Io, path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0 or buf.len == 0) return null;

    var file = (if (Dir.path.isAbsolute(path))
        Dir.openFileAbsolute(io, path, .{ .mode = .read_only })
    else
        Dir.openFile(.cwd(), io, path, .{ .mode = .read_only })) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const bytes_read = reader.interface.readSliceShort(buf) catch return null;
    if (bytes_read == 0) return null;

    return mem.trim(u8, buf[0..bytes_read], " \r\n\t");
}

/// Read a sysfs attribute and parse it into an integer or floating-point type.
pub fn readNumber(io: Io, comptime T: type, path: []const u8) ?T {
    var buf: [64]u8 = undefined;
    const line = readLine(io, path, &buf) orelse return null;
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, line, 10) catch null,
        .float => std.fmt.parseFloat(T, line) catch null,
        else => @compileError("readNumber only supports integer or float types"),
    };
}

/// Open an absolute directory for iteration or reading.
pub fn openDirAbsolute(io: Io, path: []const u8, flags: Dir.OpenOptions) !Dir {
    return Dir.openDirAbsolute(io, path, flags);
}

test "sysfs utility functions" {
    const testing = std.testing;

    try testing.expect(fileExists(testing.io, "/"));
    try testing.expect(fileExists(testing.io, "/etc"));
    try testing.expect(!fileExists(testing.io, "/non_existent_dir_12345xyz"));
}
