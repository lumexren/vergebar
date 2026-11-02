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

/// Handles loading module configuration
const Config = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const path = Dir.path;
const zon = std.zon;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;
const fmt = std.fmt;
const process = std.process;
const Environ = process.Environ;
const Map = Environ.Map;

io: Io,
environ_map: *Map,
allocator: Allocator,
arena: ?ArenaAllocator = null,

pub fn init(io: Io, allocator: Allocator, environ_map: *Map) Config {
    return .{
        .io = io,
        .environ_map = environ_map,
        .allocator = allocator,
        .arena = null,
    };
}

/// Resolves XDG_CONFIG_HOME or falls back to $HOME/.config.
/// Caller owns the returned slice and must free it.
fn resolveConfigDir(self: *Config) !?[]u8 {
    if (self.environ_map.get("XDG_CONFIG_HOME")) |dir| return try self.allocator.dupe(u8, dir);

    const home = self.environ_map.get("HOME") orelse return null;
    return try path.join(self.allocator, &.{ home, ".config" });
}

/// Resolves the absolute path to the module's ZON configuration file.
/// Caller owns the returned slice and must free it.
fn resolveModulePath(self: *Config, module_name: []const u8) !?[]u8 {
    const config_dir = try self.resolveConfigDir() orelse return null;
    defer self.allocator.free(config_dir);

    const config_file = try fmt.allocPrint(self.allocator, "{s}.zon", .{module_name});
    defer self.allocator.free(config_file);

    return try path.join(self.allocator, &.{ config_dir, "vergebar", config_file });
}

/// Checks whether a configuration file exists for the given module.
pub fn exists(self: *Config, module_name: []const u8) bool {
    const config_path = self.resolveModulePath(module_name) catch return false;
    defer self.allocator.free(config_path);

    var file = Dir.openFileAbsolute(self.io, config_path, .{ .mode = .read_only }) catch return false;
    file.close(self.io);

    return true;
}

/// Frees any allocated memory from parsed configurations.
pub fn deinit(self: *Config) void {
    if (self.arena) |*arena| {
        arena.deinit();
        self.arena = null;
    }
}

/// Frees the allocated fields of a parsed configuration struct.
pub fn free(self: *Config, _: anytype) void {
    self.deinit();
}

/// Strictly loads a typed config struct `T`. Falls back to `T{}` on any error.
/// Caller is responsible for calling `free()` on success if `T` contains allocated fields.
pub fn load(self: *Config, module_name: []const u8, comptime T: type) T {
    return self.loadExact(module_name, T) catch {
        self.deinit();
        return T{};
    };
}

/// Strictly loads a typed config struct `T`. Bubbles up all internal errors.
pub fn loadExact(self: *Config, module_name: []const u8, comptime T: type) !T {
    const config_path = try self.resolveModulePath(module_name) orelse return error.ConfigDirNotFound;
    defer self.allocator.free(config_path);

    var file = try Dir.openFileAbsolute(self.io, config_path, .{ .mode = .read_only });
    defer file.close(self.io);

    const size = try file.length(self.io);
    const buffer = try self.allocator.allocSentinel(u8, size, 0);
    defer self.allocator.free(buffer);

    var reader = file.reader(self.io, &.{});
    try reader.interface.readSliceAll(buffer);

    var arena: ArenaAllocator = .init(self.allocator);
    errdefer arena.deinit();

    var diag: zon.parse.Diagnostics = undefined;

    const res = try zon.parse.fromSlice(T, .{
        .gpa = self.allocator,
        .arena = arena.allocator(),
        .source = buffer,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    });

    if (self.arena) |*old_arena| old_arena.deinit();
    self.arena = arena;

    return res;
}
