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

pub const KeyboardMode = enum(c_uint) {
    none = 0,
    exclusive = 1,
    on_demand = 2,

    pub fn toGtk(this: KeyboardMode) c_uint {
        return @backingInt(this);
    }

    pub fn fromString(str: []const u8) KeyboardMode {
        if (mem.eql(u8, str, "exclusive")) return .exclusive;
        if (mem.eql(u8, str, "on-demand") or mem.eql(u8, str, "on_demand") or mem.eql(u8, str, "ondemand")) return .on_demand;
        return .none;
    }
};
