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
