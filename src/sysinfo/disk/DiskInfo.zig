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

/// Disk usage information for a filesystem.
const DiskInfo = @This();

const SU = @import("SizeUnit.zig");
const SizeUnit = SU.SizeUnit;

const std = @import("std");
const mem = std.mem;

path: []const u8 = "/",

total: u64 = 0,
free: u64 = 0,
used: u64 = 0,

percentage_used: u8 = 0,
percentage_free: u8 = 0,

block_size: u64 = 0,
fragment_size: u64 = 0,

inodes_total: u64 = 0,
inodes_free: u64 = 0,
inodes_used: u64 = 0,
inodes_percentage_used: u8 = 0,

/// Converts bytes to a float in the specified unit.
fn toUnit(bytes: u64, unit: SizeUnit) f64 {
    return @as(f64, @floatFromInt(bytes)) / unit.divisor();
}

pub fn totalInUnit(self: @This(), unit: SizeUnit) f64 {
    return toUnit(self.total, unit);
}

pub fn freeInUnit(self: @This(), unit: SizeUnit) f64 {
    return toUnit(self.free, unit);
}

pub fn usedInUnit(self: @This(), unit: SizeUnit) f64 {
    return toUnit(self.used, unit);
}

pub fn formatTotal(self: @This(), buf: []u8) ![]const u8 {
    return formatBytes(self.total, buf);
}

pub fn formatFree(self: @This(), buf: []u8) ![]const u8 {
    return formatBytes(self.free, buf);
}

pub fn formatUsed(self: @This(), buf: []u8) ![]const u8 {
    return formatBytes(self.used, buf);
}

/// Formats bytes into a human-readable string with auto-selected IEC unit.
pub fn formatBytes(bytes: u64, buf: []u8) ![]const u8 {
    const value: f64 = @floatFromInt(bytes);
    const unit: SizeUnit = if (value >= SU.TiB) .TiB else if (value >= SU.GiB) .GiB else if (value >= SU.MiB) .MiB else if (value >= SU.KiB) .KiB else .B;

    return mem.print(buf, "{d:.1} {s}", .{ value / unit.divisor(), unit.suffix() });
}
