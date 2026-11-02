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

const GPUInfo = @This();

const GPUMemoryInfo = @import("GPUMemoryInfo.zig");

gpu_busy: u64 = 0,
temperature: f32 = 0.0,
pwm: u64 = 0,
memory_info: GPUMemoryInfo = .{},
name: [96]u8 = @splat(0),
name_len: usize = 0,
power_usage: ?f32 = null,
power_limit: ?f32 = null,
clock_speed: ?u64 = null,
backend_name: []const u8 = "None",

pub fn getName(self: *const GPUInfo) ?[]const u8 {
    if (self.name_len > 0) return self.name[0..self.name_len];
    return null;
}

pub fn setName(self: *GPUInfo, n: []const u8) void {
    const copy_len = @min(n.len, self.name.len);
    @memcpy(self.name[0..copy_len], n[0..copy_len]);
    self.name_len = copy_len;
}
