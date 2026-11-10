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
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;
const json = std.json;
const debug = std.debug;
const Io = std.Io;
const env = @import("../env.zig");
const sysfs = @import("../sysfs.zig");

pub const jsonc = @import("jsonc.zig");
pub const Layer = @import("Layer.zig").Layer;
pub const Position = @import("Position.zig").Position;
pub const KeyboardMode = @import("KeyboardMode.zig").KeyboardMode;
pub const SharedArenaAllocator = @import("../SharedArenaAllocator.zig");
pub const ModuleSettings = @import("ModuleSettings.zig");
pub const BarConfig = @import("BarConfig.zig");

pub const DEFAULT_CONFIG: []const u8 = @embedFile("default/config.jsonc");
pub const DEFAULT_STYLE: [:0]const u8 = @embedFile("default/style.css") ++ "\x00";

fn findCandidate(io: Io, allocator: Allocator, sub_paths: []const []const u8) ?[]const u8 {
    // 1. Check $XDG_CONFIG_HOME if set and non-empty
    if (env.getXdgConfigHome()) |xdg| {
        for (sub_paths) |sub| {
            const full = allocator.print("{s}/{s}", .{ xdg, sub }) catch continue;
            if (sysfs.fileExists(io, full)) return full;
            allocator.free(full);
        }
    }

    // 2. Check fallback ~/.config
    if (env.getHome()) |home| {
        for (sub_paths) |sub| {
            const full = allocator.print("{s}/.config/{s}", .{ home, sub }) catch continue;
            if (sysfs.fileExists(io, full)) return full;
            allocator.free(full);
        }
    }

    return null;
}

pub fn findDefaultConfigPath(io: Io, allocator: Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "vergebar/config.jsonc",
        "vergebar/config.json",
        "vergebar/config",
        "vlybar/config.jsonc",
        "vlybar/config.json",
        "waybar/config.jsonc",
        "waybar/config.json",
        "waybar/config",
    };
    return findCandidate(io, allocator, &candidates);
}

pub fn findVergebarStylePath(io: Io, allocator: Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "vergebar/style.css",
        "vlybar/style.css",
    };
    return findCandidate(io, allocator, &candidates);
}

pub fn findDefaultStylePath(io: Io, allocator: Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "vergebar/style.css",
        "vlybar/style.css",
        "waybar/style.css",
    };
    return findCandidate(io, allocator, &candidates);
}

fn expandTilde(allocator: Allocator, path_str: []const u8) ![]const u8 {
    return env.expandHomeAlloc(allocator, path_str);
}

fn readFile(io: Io, allocator: Allocator, file_path: []const u8) ![]u8 {
    if (file_path.len == 0) return error.FileNotFound;
    return sysfs.readFileAlloc(io, allocator, file_path) catch return error.FileNotFound;
}

pub fn loadFromFile(io: Io, allocator: Allocator, path: []const u8) !BarConfig {
    const list = try loadConfigsFromFile(io, allocator, path);
    if (list.len == 0) return error.InvalidConfigFormat;
    return list[0];
}

pub fn loadConfigsFromFile(io: Io, allocator: Allocator, path: []const u8) ![]BarConfig {
    var arena: ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const expanded_path = try expandTilde(arena_alloc, path);
    const raw_bytes = try readFile(io, arena_alloc, expanded_path);
    return loadConfigsFromString(io, allocator, raw_bytes);
}

pub fn loadConfigsFromString(io: Io, allocator: Allocator, content: []const u8) ![]BarConfig {
    const shared: *SharedArenaAllocator = try .create(allocator);
    errdefer shared.release();
    const arena_alloc = shared.arena.allocator();

    const cleaned = try jsonc.cleanJsonc(arena_alloc, content);
    const parsed = try json.parseFromSlice(json.Value, arena_alloc, cleaned, .{});

    if (parsed.value == .object) {
        var cfg = try parseSingleBar(io, shared.arena, parsed.value.object);
        cfg.shared_arena = shared;
        var result = try allocator.alloc(BarConfig, 1);
        result[0] = cfg;
        return result;
    } else if (parsed.value == .array) {
        var list: ArrayList(BarConfig) = .empty;
        errdefer {
            for (list.items) |*cfg| cfg.deinit();
            list.deinit(allocator);
        }
        var first = true;
        for (parsed.value.array.items) |item| {
            if (item == .object) {
                if (!first) {
                    shared.retain();
                } else {
                    first = false;
                }
                var cfg = try parseSingleBar(io, shared.arena, item.object);
                cfg.shared_arena = shared;
                try list.append(allocator, cfg);
            }
        }
        if (first) {
            shared.release();
            return list.toOwnedSlice(allocator);
        }
        return list.toOwnedSlice(allocator);
    } else {
        return error.InvalidConfigFormat;
    }
}

fn parseSingleBar(io: Io, arena: ArenaAllocator, root_obj: json.ObjectMap) !BarConfig {
    var mut_arena = arena;
    const arena_alloc = mut_arena.allocator();

    var cfg: BarConfig = .{
        .arena = mut_arena,
        .modules_map = .init(arena_alloc),
    };

    if (root_obj.get("include")) |inc_val| {
        if (inc_val == .array) {
            for (inc_val.array.items) |item| {
                if (item == .string) {
                    loadInclude(io, &cfg, item.string) catch |err| {
                        debug.print("Warning: could not load include {s}: {}\n", .{ item.string, err });
                    };
                }
            }
        } else if (inc_val == .string) {
            loadInclude(io, &cfg, inc_val.string) catch |err| {
                debug.print("Warning: could not load include {s}: {}\n", .{ inc_val.string, err });
            };
        }
    }

    var it = root_obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;

        if (mem.eql(u8, k, "layer") and v == .string) {
            cfg.layer = .fromString(v.string);
        } else if (mem.eql(u8, k, "position") and v == .string) {
            cfg.position = .fromString(v.string);
        } else if ((mem.eql(u8, k, "keyboard-mode") or mem.eql(u8, k, "keyboard_mode")) and v == .string) {
            cfg.keyboard_mode = .fromString(v.string);
        } else if (mem.eql(u8, k, "output")) {
            if (v == .string) {
                var out_list: ArrayList([]const u8) = .empty;
                try out_list.append(arena_alloc, v.string);
                cfg.outputs = out_list.items;
                cfg.output = v.string;
            } else if (v == .array) {
                var out_list: ArrayList([]const u8) = .empty;
                for (v.array.items) |elem| {
                    if (elem == .string) try out_list.append(arena_alloc, elem.string);
                }
                cfg.outputs = out_list.items;
                if (cfg.outputs.len > 0) cfg.output = cfg.outputs[0];
            }
        } else if (mem.eql(u8, k, "height") and v == .integer) {
            cfg.height = @intCast(v.integer);
        } else if (mem.eql(u8, k, "width") and v == .integer) {
            cfg.width = @intCast(v.integer);
        } else if (mem.eql(u8, k, "margin-top") and v == .integer) {
            cfg.margin_top = @intCast(v.integer);
        } else if (mem.eql(u8, k, "margin-bottom") and v == .integer) {
            cfg.margin_bottom = @intCast(v.integer);
        } else if (mem.eql(u8, k, "margin-left") and v == .integer) {
            cfg.margin_left = @intCast(v.integer);
        } else if (mem.eql(u8, k, "margin-right") and v == .integer) {
            cfg.margin_right = @intCast(v.integer);
        } else if (mem.eql(u8, k, "spacing") and v == .integer) {
            cfg.spacing = @intCast(v.integer);
        } else if (mem.eql(u8, k, "reload_style_on_change") and v == .bool) {
            cfg.reload_style_on_change = v.bool;
        } else if (mem.eql(u8, k, "exclusive") and v == .bool) {
            cfg.exclusive = v.bool;
        } else if (mem.eql(u8, k, "passthrough") and v == .bool) {
            cfg.passthrough = v.bool;
        } else if (mem.eql(u8, k, "fixed-center") and v == .bool) {
            cfg.fixed_center = v.bool;
        } else if (mem.eql(u8, k, "no-center") and v == .bool) {
            cfg.no_center = v.bool;
        } else if (mem.eql(u8, k, "start_hidden") and v == .bool) {
            cfg.start_hidden = v.bool;
        } else if (mem.eql(u8, k, "mode") and v == .string) {
            cfg.mode = v.string;
        } else if (mem.eql(u8, k, "name") and v == .string) {
            cfg.name = v.string;
        } else if (mem.eql(u8, k, "on-sigusr1") and v == .string) {
            cfg.on_sigusr1 = v.string;
        } else if (mem.eql(u8, k, "on-sigusr2") and v == .string) {
            cfg.on_sigusr2 = v.string;
        } else if (mem.eql(u8, k, "modules-left") and v == .array) {
            var list: ArrayList([]const u8) = .empty;
            for (v.array.items) |elem| {
                if (elem == .string) try list.append(arena_alloc, elem.string);
            }
            cfg.modules_left = list.items;
        } else if (mem.eql(u8, k, "modules-center") and v == .array) {
            var list: ArrayList([]const u8) = .empty;
            for (v.array.items) |elem| {
                if (elem == .string) try list.append(arena_alloc, elem.string);
            }
            cfg.modules_center = list.items;
        } else if (mem.eql(u8, k, "modules-right") and v == .array) {
            var list: ArrayList([]const u8) = .empty;
            for (v.array.items) |elem| {
                if (elem == .string) try list.append(arena_alloc, elem.string);
            }
            cfg.modules_right = list.items;
        } else if (v == .object) {
            try cfg.modules_map.put(k, v);
        }
    }

    return cfg;
}

fn loadInclude(io: Io, cfg: *BarConfig, inc_path: []const u8) !void {
    const arena_alloc = cfg.arena.allocator();
    const expanded = try expandTilde(arena_alloc, inc_path);
    const raw_bytes = try readFile(io, arena_alloc, expanded);
    const cleaned = try jsonc.cleanJsonc(arena_alloc, raw_bytes);
    const parsed = try json.parseFromSlice(json.Value, arena_alloc, cleaned, .{});
    if (parsed.value != .object) return;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .object) {
            try cfg.modules_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

test "config defaults and embedded assets" {
    const testing = std.testing;

    try testing.expect(DEFAULT_CONFIG.len > 0);
    try testing.expect(DEFAULT_STYLE.len > 0);

    const layer: Layer = .fromString("top");
    try testing.expectEqual(Layer.top, layer);
    try testing.expectEqual(@as(c_uint, 2), layer.toGtk());

    const pos: Position = .fromString("bottom");
    try testing.expectEqual(Position.bottom, pos);

    try testing.expectEqual(KeyboardMode.none, KeyboardMode.fromString("none"));
    try testing.expectEqual(KeyboardMode.exclusive, KeyboardMode.fromString("exclusive"));
    try testing.expectEqual(KeyboardMode.on_demand, KeyboardMode.fromString("on-demand"));
    try testing.expectEqual(KeyboardMode.on_demand, KeyboardMode.fromString("ondemand"));
    try testing.expectEqual(@as(c_uint, 0), KeyboardMode.none.toGtk());
    try testing.expectEqual(@as(c_uint, 1), KeyboardMode.exclusive.toGtk());
    try testing.expectEqual(@as(c_uint, 2), KeyboardMode.on_demand.toGtk());
}
