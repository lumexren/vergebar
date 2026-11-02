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

const Context = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const process = std.process;
const Environ = process.Environ;

io: Io,
gpa: Allocator,
environ_map: *Environ.Map,

var global_instance: ?Context = null;

/// Initialize the global Context instance.
pub fn init(ctx: Context) void {
    global_instance = ctx;
}

/// Reset the global Context instance.
pub fn deinit() void {
    global_instance = null;
}

/// Check if the global Context has been initialized.
pub fn isInitialized() bool {
    return global_instance != null;
}

/// Retrieve the active global Context, if initialized.
pub fn get() ?Context {
    return global_instance;
}

/// Retrieve a pointer to the active global Context, if initialized.
pub fn getPtr() ?*const Context {
    if (global_instance) |*ctx| return ctx;
    return null;
}

// -------------------------------------------------------------------------
// Instance Methods
// -------------------------------------------------------------------------

/// Retrieve an environment variable using this Context instance.
pub fn env(self: Context, key: []const u8) ?[]const u8 {
    return self.environ_map.get(key);
}

/// Check if a file or directory exists at an absolute path.
pub fn checkFileExists(self: Context, file_path: []const u8) bool {
    Dir.accessAbsolute(self.io, file_path, .{}) catch return false;
    return true;
}

/// Read an entire file into memory using the provided allocator.
pub fn readEntireFile(self: Context, allocator: Allocator, file_path: []const u8) ![]u8 {
    var file = try Dir.openFileAbsolute(self.io, file_path, .{ .mode = .read_only });
    defer file.close(self.io);

    var io_buf: [4096]u8 = undefined;
    var r = file.reader(self.io, &io_buf);
    return try r.interface.allocRemaining(allocator, .unlimited);
}

/// Run a command via `/bin/sh -c` and return stdout allocated on the heap.
pub fn execShellAlloc(self: Context, allocator: Allocator, cmd: []const u8) ![]u8 {
    var child = try process.spawn(self.io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var io_buf: [4096]u8 = undefined;
    var f_reader = child.stdout.?.reader(self.io, &io_buf);
    const out = try f_reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(out);

    _ = try child.wait(self.io);
    return out;
}

/// Run a command via `/bin/sh -c` and fill caller-supplied buffer without allocation.
pub fn execShellBuf(self: Context, cmd: []const u8, out_buf: []u8) usize {
    var child = process.spawn(self.io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return 0;

    var f_reader = child.stdout.?.reader(self.io, &.{});
    const n = f_reader.interface.readSliceShort(out_buf) catch 0;
    _ = child.wait(self.io) catch {};
    return n;
}

/// Spawn a long-running shell streaming process with piped stdout.
pub fn spawnStream(self: Context, cmd: []const u8) !process.Child {
    return try process.spawn(self.io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout = .pipe,
        .stderr = .ignore,
    });
}

// -------------------------------------------------------------------------
// Global Static Convenience Functions
// -------------------------------------------------------------------------

/// Retrieve an environment variable value by key.
/// Looks up from the active Context's environ_map.
pub fn getEnv(key: []const u8) ?[]const u8 {
    if (global_instance) |ctx| {
        return ctx.environ_map.get(key);
    }
    return null;
}

/// Check if an environment variable exists and is non-empty.
pub fn hasEnv(key: []const u8) bool {
    const val = getEnv(key) orelse return false;
    return val.len > 0;
}

/// Check if a file or directory exists at the given path.
pub fn fileExists(file_path: []const u8) bool {
    if (global_instance) |ctx| {
        Dir.accessAbsolute(ctx.io, file_path, .{}) catch return false;
        return true;
    }
    return false;
}

/// Read an entire file into a heap-allocated buffer.
pub fn readFileAlloc(allocator: Allocator, file_path: []const u8) ![]u8 {
    const ctx = global_instance orelse return error.NoContext;
    return ctx.readEntireFile(allocator, file_path);
}

/// Read the first line of a sysfs/procfs attribute into `buf`.
/// Trims leading and trailing whitespace/newlines.
pub fn readSysfsLine(path: []const u8, buf: []u8) ?[]const u8 {
    const ctx = global_instance orelse return null;
    if (path.len == 0 or buf.len == 0) return null;

    var file = Dir.openFileAbsolute(ctx.io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(ctx.io);

    var reader = file.reader(ctx.io, &.{});
    const bytes_read = reader.interface.readSliceShort(buf) catch return null;
    if (bytes_read == 0) return null;

    return mem.trim(u8, buf[0..bytes_read], " \r\n\t");
}

/// Read a sysfs attribute and parse it into an integer or floating-point type.
pub fn readSysfsNumber(comptime T: type, path: []const u8) ?T {
    var buf: [64]u8 = undefined;
    const line = readSysfsLine(path, &buf) orelse return null;
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, line, 10) catch null,
        .float => std.fmt.parseFloat(T, line) catch null,
        else => @compileError("readSysfsNumber only supports integer or float types"),
    };
}

/// Execute a shell command via `/bin/sh -c` and capture stdout on heap.
pub fn runShellAlloc(allocator: Allocator, cmd: []const u8) ![]u8 {
    const ctx = global_instance orelse return error.NoContext;
    return ctx.execShellAlloc(allocator, cmd);
}

/// Execute a shell command via `/bin/sh -c` and return a trimmed heap-allocated string.
pub fn runShellTrimAlloc(allocator: Allocator, cmd: []const u8) ![]u8 {
    const raw = try runShellAlloc(allocator, cmd);
    defer allocator.free(raw);
    const trimmed = mem.trim(u8, raw, " \r\n\t");
    return try allocator.dupe(u8, trimmed);
}

/// Execute a shell command via `/bin/sh -c` into a caller-supplied buffer without allocations.
pub fn runShellBuf(cmd: []const u8, out_buf: []u8) usize {
    const ctx = global_instance orelse return 0;
    return ctx.execShellBuf(cmd, out_buf);
}

/// Execute a shell command and return a trimmed slice within `out_buf`.
pub fn runShellTrimBuf(cmd: []const u8, out_buf: []u8) []const u8 {
    const n = runShellBuf(cmd, out_buf);
    if (n == 0) return "";
    return mem.trim(u8, out_buf[0..n], " \r\n\t");
}

/// Spawn a long-running streaming child process with piped stdout.
pub fn spawnShellStream(cmd: []const u8) !process.Child {
    const ctx = global_instance orelse return error.NoContext;
    return ctx.spawnStream(cmd);
}

/// Run a command and return its exit status code.
pub fn runShellExitCode(cmd: []const u8) ?u8 {
    const ctx = global_instance orelse return null;
    var child = process.spawn(ctx.io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    const term = child.wait(ctx.io) catch return null;
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

/// Sleep for `sec` seconds using the active Context's Io.
pub fn sleepSeconds(sec: u32) void {
    if (global_instance) |ctx| {
        ctx.io.sleep(.fromSeconds(@intCast(sec)), .boot) catch {};
    }
}

/// Sleep for `ms` milliseconds using the active Context's Io.
pub fn sleepMs(ms: u32) void {
    if (global_instance) |ctx| {
        ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .boot) catch {};
    }
}

/// Retrieve the current user's home directory.
pub fn getHome() ?[]const u8 {
    return getEnv("HOME");
}

/// Retrieve the XDG runtime directory (defaults to `/run/user/1000` if unset).
pub fn getRuntimeDir() []const u8 {
    return getEnv("XDG_RUNTIME_DIR") orelse "/run/user/1000";
}

/// Retrieve the raw $XDG_CONFIG_HOME environment variable, if set and non-empty.
pub fn getXdgConfigHome() ?[]const u8 {
    const val = getEnv("XDG_CONFIG_HOME") orelse return null;
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
            return std.fmt.allocPrint(allocator, "{s}/.config", .{home}) catch null;
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
    const trimmed = mem.trimLeft(u8, subpath, "/");
    if (getXdgConfigHome()) |dir| {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, trimmed });
    }
    if (getHome()) |home| {
        if (home.len > 0) {
            return try std.fmt.allocPrint(allocator, "{s}/.config/{s}", .{ home, trimmed });
        }
    }
    return null;
}

/// Resolve a configuration subpath relative to $XDG_CONFIG_HOME (or fallback $HOME/.config) into a caller buffer.
pub fn resolveConfigPathBuf(subpath: []const u8, out_buf: []u8) ?[]const u8 {
    const base = getConfigHomeBuf(out_buf) orelse return null;
    const base_len = base.len;
    const trimmed = mem.trimLeft(u8, subpath, "/");
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
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, path[2..] });
        }
    }
    return try allocator.dupe(u8, path);
}

test "Context environment and path helpers" {
    const testing = std.testing;

    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/bin:/bin");
    try env_map.put("HOME", "/home/test");

    const io = std.testing.io;
    Context.init(.{
        .io = io,
        .gpa = testing.allocator,
        .environ_map = &env_map,
    });
    defer Context.deinit();

    const path_env = Context.getEnv("PATH");
    try testing.expect(path_env != null);
    try testing.expect(Context.hasEnv("PATH"));

    try testing.expect(Context.getEnv("NON_EXISTENT_VAR_12345XYZ") == null);
    try testing.expect(!Context.hasEnv("NON_EXISTENT_VAR_12345XYZ"));

    try testing.expect(Context.fileExists("/"));
    try testing.expect(Context.fileExists("/etc"));
    try testing.expect(!Context.fileExists("/non_existent_dir_12345xyz"));

    var buf: [256]u8 = undefined;
    const expanded = Context.expandHomeBuf("foo/bar", &buf);
    try testing.expectEqualStrings("foo/bar", expanded);

    // XDG_CONFIG_HOME resolution
    var cfg_buf: [256]u8 = undefined;
    const cfg_dir = Context.getConfigHomeBuf(&cfg_buf);
    if (Context.hasXdgConfigHome() or Context.getHome() != null) {
        try testing.expect(cfg_dir != null);
        try testing.expect(cfg_dir.?.len > 0);
    }

    Context.sleepMs(1);
}
