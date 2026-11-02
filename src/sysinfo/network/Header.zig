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

/// DNS Header (12 bytes)
const Header = @This();

const std = @import("std");
const mem = std.mem;

id: u16,
flags: u16,
qdcount: u16,
ancount: u16,
nscount: u16,
arcount: u16,

pub fn toBytes(self: Header) [12]u8 {
    var buf: [12]u8 = undefined;
    inline for (.{ self.id, self.flags, self.qdcount, self.ancount, self.nscount, self.arcount }, 0..) |val, i| mem.writeInt(u16, buf[i * 2 ..][0..2], val, .big);
    return buf;
}

pub fn fromBytes(bytes: *const [12]u8) Header {
    return .{
        .id = mem.readInt(u16, bytes[0..2], .big),
        .flags = mem.readInt(u16, bytes[2..4], .big),
        .qdcount = mem.readInt(u16, bytes[4..6], .big),
        .ancount = mem.readInt(u16, bytes[6..8], .big),
        .nscount = mem.readInt(u16, bytes[8..10], .big),
        .arcount = mem.readInt(u16, bytes[10..12], .big),
    };
}
