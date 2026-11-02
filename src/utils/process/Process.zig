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

/// Process information retrieved from the /proc filesystem.
const Process = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const fs = std.fs;
const os = std.os;
const linux = os.linux;
const posix = std.posix;
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const comm_buf_len = 20;
pub const cmdline_max = 4096;

/// Process name from /proc/<pid>/comm (trimmed, null-terminated for free).
name: []const u8,
/// Process ID.
pid: posix.pid_t,

/// Send a real-time signal at SIGRTMIN + `offset`.
pub inline fn sendRtSignal(self: Process, offset: u8) !void {
    try posix.kill(self.pid, @fromBackingInt(@intCast(linux.sigrtmin() + @as(i32, offset))));
}

/// Send a real-time signal at SIGRTMAX - `offset`.
pub inline fn sendRtMaxSignal(self: Process, offset: u8) !void {
    try posix.kill(self.pid, @fromBackingInt(@intCast(linux.sigrtmax() - @as(i32, offset))));
}

/// Send an arbitrary signal number to the process.
pub inline fn sendSignal(self: Process, sig: i32) !void {
    try posix.kill(self.pid, @fromBackingInt(@intCast(sig)));
}

/// Request graceful termination (SIGTERM).
pub inline fn terminate(self: Process) !void {
    try posix.kill(self.pid, posix.SIG.TERM);
}

/// Force kill the process (SIGKILL).
pub inline fn kill(self: Process) !void {
    try posix.kill(self.pid, posix.SIG.KILL);
}

/// Suspend the process (SIGSTOP).
pub inline fn pause(self: Process) !void {
    try posix.kill(self.pid, posix.SIG.STOP);
}

/// Resume a suspended process (SIGCONT). Named `resume_` because `resume` is reserved.
pub inline fn resume_(self: Process) !void {
    try posix.kill(self.pid, posix.SIG.CONT);
}

/// Check whether the process is still alive.
///
/// Uses `kill(pid, 0)` — a single syscall with no filesystem I/O, making
/// this significantly cheaper than the previous /proc access approach.
/// Returns `false` for ESRCH (not found) and EPERM (no permission to signal,
/// but the process exists — treated conservatively as alive).
pub fn isAlive(self: Process) bool {
    posix.kill(self.pid, 0) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => {},
    };
    return true;
}

/// Read the process's argv from /proc/<pid>/cmdline.
///
/// The kernel stores cmdline as NUL-separated tokens. The caller owns the
/// returned slice and must free it with `allocator`.
pub fn getCmdline(self: Process, io: Io, allocator: Allocator) ![]u8 {
    var path_buf: [32]u8 = undefined;
    const path = try mem.print(&path_buf, "/proc/{d}/cmdline", .{self.pid});

    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    return file.readToEndAlloc(io, allocator, cmdline_max);
}

/// Read the process's argv from /proc/<pid>/cmdline into `buf`.
///
/// Returns the slice of `buf` that was written, capped at `buf.len`.
/// Prefer this over `getCmdline` when you want to avoid an allocation.
pub fn getCmdlineInto(self: Process, io: Io, buf: []u8) ![]u8 {
    var path_buf: [32]u8 = undefined;
    const path = try mem.print(&path_buf, "/proc/{d}/cmdline", .{self.pid});

    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var slices: [1][]u8 = .{buf};
    const n = try file.readStreaming(io, slices[0..]);
    return buf[0..n];
}

/// Read the process's environment from /proc/<pid>/environ.
///
/// The kernel stores environ as NUL-separated KEY=VALUE pairs. Caller owns
/// the returned slice and must free it with `allocator`.
pub fn getEnviron(self: Process, io: Io, allocator: Allocator) ![]u8 {
    var path_buf: [32]u8 = undefined;
    const path = try mem.print(&path_buf, "/proc/{d}/environ", .{self.pid});

    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    return file.readToEndAlloc(io, allocator, 64 * 1024);
}

/// Read the process's current working directory from /proc/<pid>/cwd.
///
/// Resolves the symlink and returns the path. Caller owns the returned
/// slice and must free it with `allocator`.
pub fn getCwd(self: Process, io: Io, allocator: Allocator) ![]u8 {
    var path_buf: [32]u8 = undefined;
    const path = try mem.print(&path_buf, "/proc/{d}/cwd", .{self.pid});

    var result_buf: [fs.max_path_bytes]u8 = undefined;
    const resolved = try Dir.readLinkAbsolute(io, path, &result_buf);
    return allocator.dupe(u8, resolved);
}

/// Read a single field from /proc/<pid>/status by key (e.g. "VmRSS").
///
/// Returns the raw value string (trimmed), or `null` if the key is absent.
/// Uses stack storage only — no allocation.
pub fn getStatusField(self: Process, io: Io, key: []const u8, buf: []u8) !?[]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = try mem.print(&path_buf, "/proc/{d}/status", .{self.pid});

    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var slices: [1][]u8 = .{file_buf[0..]};
    const n = try file.readStreaming(io, slices[0..]);
    const content = file_buf[0..n];

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!mem.startsWith(u8, line, key)) continue;
        const colon = mem.findScalar(u8, line, ':') orelse continue;
        const value = mem.trim(u8, line[colon + 1 ..], &ascii.whitespace);
        if (value.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..value.len], value);
        return buf[0..value.len];
    }

    return null;
}
