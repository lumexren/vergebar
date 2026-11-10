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

const PipewireInfo = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

volume: u8,
raw_volume: f64,
muted: bool,
node_name: []const u8,
is_sink: bool = true,

pub fn deinit(this: *PipewireInfo, allocator: Allocator) void {
    allocator.free(this.node_name);
    this.* = undefined;
}
