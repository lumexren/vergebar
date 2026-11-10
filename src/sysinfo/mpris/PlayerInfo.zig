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

const PlayerInfo = @This();

const PlaybackStatus = @import("PlaybackStatus.zig").PlaybackStatus;
const LoopStatus = @import("LoopStatus.zig").LoopStatus;
const Metadata = @import("Metadata.zig");

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

name: []const u8,
identity: ?[]const u8 = null,
status: PlaybackStatus = .stopped,
loop_status: LoopStatus = .none,
shuffle: bool = false,
volume: f64 = 1.0,
position_us: i64 = 0,
metadata: Metadata = .{},

can_control: bool = false,
can_go_next: bool = false,
can_go_previous: bool = false,
can_play: bool = false,
can_pause: bool = false,
can_seek: bool = false,

pub fn deinit(this: *@This(), allocator: Allocator) void {
    allocator.free(this.name);
    if (this.identity) |v| allocator.free(v);
    this.metadata.deinit(allocator);
    this.* = undefined;
}
