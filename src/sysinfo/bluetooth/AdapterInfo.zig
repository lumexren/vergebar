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

/// Bluetooth adapter information
const AdapterInfo = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

path: []const u8,
name: ?[]const u8 = null,
address: ?[]const u8 = null,
powered: bool = false,
discoverable: bool = false,
discovering: bool = false,

pub fn deinit(self: *AdapterInfo, allocator: Allocator) void {
    allocator.free(self.path);
    if (self.name) |n| allocator.free(n);
    if (self.address) |a| allocator.free(a);
    self.* = undefined;
}
