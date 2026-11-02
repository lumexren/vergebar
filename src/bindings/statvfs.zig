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
const linux = std.os.linux;

pub const Statfs = extern struct {
    f_type: isize,
    f_bsize: isize,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: isize,
    f_frsize: isize,
    f_flags: isize,
    f_spare: [4]isize,
};

/// Pure Zig native Linux statfs syscall (eliminates libc extern C dependency)
pub fn statfs(path: [*:0]const u8, buf: *Statfs) usize {
    const rc = linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(buf));
    return if (linux.errno(rc) == .SUCCESS) 0 else 1;
}
