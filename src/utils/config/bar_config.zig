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
const StringHashMap = std.StringHashMap;
const fmt = std.fmt;
const debug = std.debug;
const Io = std.Io;
const Dir = Io.Dir;
const jsonc = @import("jsonc.zig");
const Context = @import("../context.zig");

pub const Layer = enum(c_uint) {
    background = 0,
    bottom = 1,
    top = 2,
    overlay = 3,

    pub fn toGtk(self: Layer) c_uint {
        return @intFromEnum(self);
    }

    pub fn fromString(str: []const u8) Layer {
        if (mem.eql(u8, str, "background")) return .background;
        if (mem.eql(u8, str, "bottom")) return .bottom;
        if (mem.eql(u8, str, "overlay")) return .overlay;
        return .top;
    }
};

pub const Position = enum {
    top,
    bottom,
    left,
    right,

    pub fn fromString(str: []const u8) Position {
        if (mem.eql(u8, str, "bottom")) return .bottom;
        if (mem.eql(u8, str, "left")) return .left;
        if (mem.eql(u8, str, "right")) return .right;
        return .top;
    }
};

pub const ModuleSettings = struct {
    arena: *ArenaAllocator,
    value: json.Value,

    pub fn getString(self: ModuleSettings, key: []const u8) ?[]const u8 {
        if (self.value != .object) return null;
        if (self.value.object.get(key)) |val| {
            if (val == .string) return val.string;
        }
        return null;
    }

    pub fn getInt(self: ModuleSettings, key: []const u8) ?i64 {
        if (self.value != .object) return null;
        if (self.value.object.get(key)) |val| {
            if (val == .integer) return val.integer;
            if (val == .float) return @intFromFloat(val.float);
        }
        return null;
    }

    pub fn getFloat(self: ModuleSettings, key: []const u8) ?f64 {
        if (self.value != .object) return null;
        if (self.value.object.get(key)) |val| {
            if (val == .float) return val.float;
            if (val == .integer) return @floatFromInt(val.integer);
        }
        return null;
    }

    pub fn getBool(self: ModuleSettings, key: []const u8) ?bool {
        if (self.value != .object) return null;
        if (self.value.object.get(key)) |val| {
            if (val == .bool) return val.bool;
        }
        return null;
    }
};

pub const BarConfig = struct {
    arena: ArenaAllocator,
    layer: Layer = .top,
    position: Position = .top,
    output: ?[]const u8 = null,
    height: ?i32 = null,
    width: ?i32 = null,
    margin_top: i32 = 0,
    margin_bottom: i32 = 0,
    margin_left: i32 = 0,
    margin_right: i32 = 0,
    spacing: i32 = 4,
    outputs: [][]const u8 = &.{},
    reload_style_on_change: bool = false,
    exclusive: bool = true,
    passthrough: bool = false,
    fixed_center: bool = true,
    no_center: bool = false,
    start_hidden: bool = false,
    name: ?[]const u8 = null,
    on_sigusr1: ?[]const u8 = null,
    on_sigusr2: ?[]const u8 = null,

    modules_left: [][]const u8 = &.{},
    modules_center: [][]const u8 = &.{},
    modules_right: [][]const u8 = &.{},

    modules_map: StringHashMap(json.Value),

    pub fn deinit(self: *BarConfig) void {
        self.arena.deinit();
    }

    pub fn matchesOutput(self: BarConfig, connector: []const u8) bool {
        if (self.outputs.len == 0) return true;
        for (self.outputs) |out| {
            if (mem.eql(u8, out, "*")) return true;
            if (mem.startsWith(u8, out, "!")) {
                if (mem.eql(u8, out[1..], connector)) return false;
            } else if (mem.eql(u8, out, connector)) {
                return true;
            }
        }
        var all_negative = true;
        for (self.outputs) |out| {
            if (!mem.startsWith(u8, out, "!")) {
                all_negative = false;
                break;
            }
        }
        return all_negative;
    }

    pub fn getModuleSettings(self: *BarConfig, name: []const u8) ModuleSettings {
        const val = self.modules_map.get(name) orelse json.Value{ .object = .empty };
        return .{
            .arena = &self.arena,
            .value = val,
        };
    }
};

fn expandTilde(allocator: Allocator, path_str: []const u8) ![]const u8 {
    if (mem.startsWith(u8, path_str, "~/")) {
        if (Context.getEnv("HOME")) |home| {
            return try fmt.allocPrint(allocator, "{s}/{s}", .{ home, path_str[2..] });
        }
    }
    return try allocator.dupe(u8, path_str);
}

fn readFile(allocator: Allocator, file_path: []const u8) ![]u8 {
    if (file_path.len == 0) return error.FileNotFound;
    const ctx = Context.get() orelse return error.NoContext;

    var file = Dir.openFileAbsolute(ctx.io, file_path, .{ .mode = .read_only }) catch return error.FileNotFound;
    defer file.close(ctx.io);

    var io_buf: [4096]u8 = undefined;
    var r = file.reader(ctx.io, &io_buf);
    return r.interface.allocRemaining(allocator, .unlimited) catch error.ReadError;
}

pub fn loadFromFile(allocator: Allocator, path: []const u8) !BarConfig {
    const list = try loadConfigsFromFile(allocator, path);
    if (list.len == 0) return error.InvalidConfigFormat;
    return list[0];
}

pub fn loadConfigsFromFile(allocator: Allocator, path: []const u8) ![]BarConfig {
    var arena: ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const expanded_path = try expandTilde(arena_alloc, path);
    const raw_bytes = try readFile(arena_alloc, expanded_path);
    return loadConfigsFromString(allocator, raw_bytes);
}

pub fn loadConfigsFromString(allocator: Allocator, content: []const u8) ![]BarConfig {
    var arena: ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const cleaned = try jsonc.cleanJsonc(arena_alloc, content);
    const parsed = try json.parseFromSlice(json.Value, arena_alloc, cleaned, .{});

    if (parsed.value == .object) {
        const cfg = try parseSingleBar(arena, parsed.value.object);
        var result = try allocator.alloc(BarConfig, 1);
        result[0] = cfg;
        return result;
    } else if (parsed.value == .array) {
        var list: ArrayList(BarConfig) = .empty;
        for (parsed.value.array.items, 0..) |item, idx| {
            if (item == .object) {
                const bar_arena: ArenaAllocator = if (idx == 0) arena else .init(allocator);
                const cfg = try parseSingleBar(bar_arena, item.object);
                try list.append(allocator, cfg);
            }
        }
        return list.toOwnedSlice(allocator);
    } else {
        return error.InvalidConfigFormat;
    }
}

fn parseSingleBar(arena: ArenaAllocator, root_obj: json.ObjectMap) !BarConfig {
    var mut_arena = arena;
    const arena_alloc = mut_arena.allocator();

    var cfg: BarConfig = .{
        .arena = mut_arena,
        .modules_map = StringHashMap(json.Value).init(arena_alloc),
    };

    if (root_obj.get("include")) |inc_val| {
        if (inc_val == .array) {
            for (inc_val.array.items) |item| {
                if (item == .string) {
                    loadInclude(&cfg, item.string) catch |err| {
                        debug.print("Warning: could not load include {s}: {}\n", .{ item.string, err });
                    };
                }
            }
        } else if (inc_val == .string) {
            loadInclude(&cfg, inc_val.string) catch |err| {
                debug.print("Warning: could not load include {s}: {}\n", .{ inc_val.string, err });
            };
        }
    }

    var it = root_obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;

        if (mem.eql(u8, k, "layer") and v == .string) {
            cfg.layer = Layer.fromString(v.string);
        } else if (mem.eql(u8, k, "position") and v == .string) {
            cfg.position = Position.fromString(v.string);
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

fn loadInclude(cfg: *BarConfig, inc_path: []const u8) !void {
    const arena_alloc = cfg.arena.allocator();
    const expanded = try expandTilde(arena_alloc, inc_path);
    const raw_bytes = try readFile(arena_alloc, expanded);
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
