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

const BarConfig = @This();

pub const Layer = @import("Layer.zig").Layer;
pub const Position = @import("Position.zig").Position;
pub const KeyboardMode = @import("KeyboardMode.zig").KeyboardMode;
pub const ModuleSettings = @import("ModuleSettings.zig");
pub const SharedArenaAllocator = @import("../SharedArenaAllocator.zig");

const std = @import("std");
const mem = std.mem;
const json = std.json;
const StringHashMap = std.StringHashMap;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;

arena: ArenaAllocator,
layer: Layer = .top,
position: Position = .top,
keyboard_mode: KeyboardMode = .none,
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
mode: []const u8 = "dock",
name: ?[]const u8 = null,
on_sigusr1: ?[]const u8 = null,
on_sigusr2: ?[]const u8 = null,

modules_left: [][]const u8 = &.{},
modules_center: [][]const u8 = &.{},
modules_right: [][]const u8 = &.{},

modules_map: StringHashMap(json.Value),
shared_arena: ?*SharedArenaAllocator = null,

pub fn deinit(this: *BarConfig) void {
    if (this.shared_arena) |sa| {
        sa.release();
    } else {
        this.arena.deinit();
    }
}

pub fn matchesOutput(this: BarConfig, connector: []const u8) bool {
    if (this.outputs.len == 0) return true;
    for (this.outputs) |out| {
        if (mem.eql(u8, out, "*")) return true;
        if (mem.startsWith(u8, out, "!")) {
            if (mem.eql(u8, out[1..], connector)) return false;
        } else if (mem.eql(u8, out, connector)) {
            return true;
        }
    }
    var all_negative = true;
    for (this.outputs) |out| {
        if (!mem.startsWith(u8, out, "!")) {
            all_negative = false;
            break;
        }
    }
    return all_negative;
}

pub fn getModuleSettings(this: *BarConfig, name: []const u8) ModuleSettings {
    const val: json.Value = this.modules_map.get(name) orelse .{ .object = .empty };
    return .{
        .arena = &this.arena,
        .value = val,
    };
}
