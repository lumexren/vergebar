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
const process = std.process;

/// Execute a shell command via `/bin/sh -c` and fill caller-supplied buffer without allocation.
pub fn runBuf(io: Io, cmd: []const u8, out_buf: []u8) usize {
    var child = process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return 0;

    var f_reader = child.stdout.?.reader(io, &.{});
    const n = f_reader.interface.readSliceShort(out_buf) catch 0;
    _ = child.wait(io) catch {};
    return n;
}

/// Execute a shell command and return a trimmed slice within `out_buf`.
pub fn runTrimBuf(io: Io, cmd: []const u8, out_buf: []u8) []const u8 {
    const n = runBuf(io, cmd, out_buf);
    if (n == 0) return "";
    return mem.trim(u8, out_buf[0..n], " \r\n\t");
}

/// Execute a shell command via `/bin/sh -c` and return stdout allocated on the heap.
pub fn runAlloc(io: Io, allocator: Allocator, cmd: []const u8) ![]u8 {
    var child = try process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var io_buf: [4096]u8 = undefined;
    var f_reader = child.stdout.?.reader(io, &io_buf);
    const out = try f_reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(out);

    _ = try child.wait(io);
    return out;
}

/// Execute a shell command via `/bin/sh -c` and return a trimmed heap-allocated string.
pub fn runTrimAlloc(io: Io, allocator: Allocator, cmd: []const u8) ![]u8 {
    const raw = try runAlloc(io, allocator, cmd);
    const trimmed = mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == raw.len) return raw;
    defer allocator.free(raw);
    return try allocator.dupe(u8, trimmed);
}

/// Spawn a long-running streaming child process with piped stdout.
pub fn spawnStream(io: Io, cmd: []const u8) !process.Child {
    return try process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout = .pipe,
        .stderr = .ignore,
    });
}

/// Run a command and return its exit status code.
pub fn runExitCode(io: Io, cmd: []const u8) ?u8 {
    var child = process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    const term = child.wait(io) catch return null;
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

/// Sleep for `sec` seconds using the given Io.
pub fn sleepSeconds(io: Io, sec: u32) void {
    io.sleep(.fromSeconds(@intCast(sec)), .boot) catch {};
}

/// Sleep for `ms` milliseconds using the given Io.
pub fn sleepMs(io: Io, ms: u32) void {
    io.sleep(.fromMilliseconds(@intCast(ms)), .boot) catch {};
}

test "sh utility functions" {
    const testing = std.testing;

    var buf: [64]u8 = undefined;
    const trimmed = runTrimBuf(testing.io, "echo hello", &buf);
    try testing.expectEqualStrings("hello", trimmed);

    const alloc_out = try runTrimAlloc(testing.io, testing.allocator, "echo world");
    defer testing.allocator.free(alloc_out);
    try testing.expectEqualStrings("world", alloc_out);

    sleepMs(testing.io, 1);
}
