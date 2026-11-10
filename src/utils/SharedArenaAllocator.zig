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

const SharedArenaAllocator = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;

allocator: Allocator,
arena: ArenaAllocator,
ref_count: usize,

pub fn create(allocator: Allocator) !*SharedArenaAllocator {
    const this = try allocator.create(SharedArenaAllocator);
    this.* = .{
        .allocator = allocator,
        .arena = .init(allocator),
        .ref_count = 1,
    };
    return this;
}

pub fn retain(this: *SharedArenaAllocator) void {
    this.ref_count += 1;
}

pub fn release(this: *SharedArenaAllocator) void {
    if (this.ref_count > 1) {
        this.ref_count -= 1;
    } else {
        this.arena.deinit();
        this.allocator.destroy(this);
    }
}
