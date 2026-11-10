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
const fmt = std.fmt;
const Io = std.Io;
const sysfs = @import("utils").sysfs;

pub const LoadAvg = struct {
    load1: f64,
    load5: f64,
    load15: f64,
};

/// Reads the system 1, 5, and 15-minute load averages from /proc/loadavg.
pub fn read(io: Io) ?LoadAvg {
    var buf: [64]u8 = undefined;
    const line = sysfs.readLine(io, "/proc/loadavg", &buf) orelse return null;

    var tokens = mem.tokenizeScalar(u8, line, ' ');
    const l1_str = tokens.next() orelse return null;
    const l5_str = tokens.next() orelse return null;
    const l15_str = tokens.next() orelse return null;

    const l1 = fmt.parseFloat(f64, l1_str) catch 0.0;
    const l5 = fmt.parseFloat(f64, l5_str) catch 0.0;
    const l15 = fmt.parseFloat(f64, l15_str) catch 0.0;

    return .{
        .load1 = l1,
        .load5 = l5,
        .load15 = l15,
    };
}
