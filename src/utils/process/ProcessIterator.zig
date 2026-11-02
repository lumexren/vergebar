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

/// Iterator over all /proc entries that match a given process name.
///
/// Returned `Process` values borrow their `name` field from `target_name`,
/// so `target_name` must outlive all values produced by `next`.
const ProcessIterator = @This();

const Process = @import("Process.zig");
const helpers = @import("helpers.zig");

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const mem = std.mem;
const fmt = std.fmt;
const posix = std.posix;

dir: Dir,
it: Dir.Iterator,
target_name: []const u8,
io: Io,

/// Advance to the next matching process, or return `null` when exhausted.
pub fn next(self: *ProcessIterator) !?Process {
    var comm_buf: [Process.comm_buf_len]u8 = undefined;

    while (try self.it.next(self.io)) |entry| {
        if (entry.kind != .directory or !ascii.isDigit(entry.name[0])) continue;

        const name = helpers.readCommInto(self.io, entry.name, &comm_buf) catch continue;
        if (!mem.eql(u8, name, self.target_name)) continue;

        const pid = fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;
        return .{ .name = self.target_name, .pid = pid };
    }

    return null;
}

/// Close the underlying /proc directory handle.
pub inline fn deinit(self: *ProcessIterator) void {
    self.dir.close(self.io);
}
