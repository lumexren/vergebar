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
const Context = @import("../context.zig");

pub const jsonc = @import("jsonc.zig");
pub const bar_config = @import("bar_config.zig");
pub const BarConfig = bar_config.BarConfig;
pub const Layer = bar_config.Layer;
pub const Position = bar_config.Position;
pub const ModuleSettings = bar_config.ModuleSettings;
pub const Loader = @import("loader.zig");
pub const Config = Loader;

pub const DEFAULT_CONFIG: []const u8 = @embedFile("default/config.jsonc");
pub const DEFAULT_STYLE: [:0]const u8 = @embedFile("default/style.css") ++ "\x00";

fn findCandidate(allocator: Allocator, sub_paths: []const []const u8) ?[]const u8 {
    // 1. Check $XDG_CONFIG_HOME if set and non-empty
    if (Context.getXdgConfigHome()) |xdg| {
        for (sub_paths) |sub| {
            const full = allocator.print("{s}/{s}", .{ xdg, sub }) catch continue;
            if (Context.fileExists(full)) return full;
            allocator.free(full);
        }
    }

    // 2. Check fallback ~/.config
    if (Context.getHome()) |home| {
        for (sub_paths) |sub| {
            const full = allocator.print("{s}/.config/{s}", .{ home, sub }) catch continue;
            if (Context.fileExists(full)) return full;
            allocator.free(full);
        }
    }

    return null;
}

pub fn findDefaultConfigPath(allocator: Allocator) ?[]const u8 {
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
    return findCandidate(allocator, &candidates);
}

pub fn findVergebarStylePath(allocator: Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "vergebar/style.css",
        "vlybar/style.css",
    };
    return findCandidate(allocator, &candidates);
}

pub fn findDefaultStylePath(allocator: Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "vergebar/style.css",
        "vlybar/style.css",
        "waybar/style.css",
    };
    return findCandidate(allocator, &candidates);
}

test "config defaults and embedded assets" {
    const testing = std.testing;

    try testing.expect(DEFAULT_CONFIG.len > 0);
    try testing.expect(DEFAULT_STYLE.len > 0);

    const layer = Layer.fromString("top");
    try testing.expectEqual(Layer.top, layer);
    try testing.expectEqual(@as(c_uint, 2), layer.toGtk());

    const pos = Position.fromString("bottom");
    try testing.expectEqual(Position.bottom, pos);
}
