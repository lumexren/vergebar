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

/// Watcher blocks SIGUSR1 and SIGUSR2 signals and monitors them
/// via Linux signalfd, allowing zero-CPU sleep waiting while instantly
/// waking on external signals from Waybar or user commands.
const Watcher = @This();

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const os = std.os;
const linux = os.linux;
const testing = std.testing;

sfd: posix.fd_t,

pub fn init() !Watcher {
    var mask: posix.sigset_t = mem.zeroes(posix.sigset_t);
    posix.sigaddset(&mask, posix.SIG.USR1);
    posix.sigaddset(&mask, posix.SIG.USR2);

    const builtin = @import("builtin");
    const start_rt: u32 = if (builtin.link_libc) 34 else 32;
    var sig_num: u32 = start_rt;
    while (sig_num <= 64) : (sig_num += 1) posix.sigaddset(&mask, @fromBackingInt(@intCast(sig_num)));
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    const sfd = try posix.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
    return .{ .sfd = sfd };
}

pub fn deinit(this: *Watcher) void {
    _ = posix.system.close(this.sfd);
    this.sfd = -1;
}

/// Waits for either the specified duration in seconds or an incoming signal (SIGUSR1/SIGUSR2).
/// If interrupted by a signal, drains the signalfd and returns true.
/// If timeout expires without signal, returns false.
pub fn waitSeconds(this: *Watcher, seconds: i64) bool {
    const timeout_ms: i32 = if (seconds <= 0) 0 else if (seconds > 2147483) 2147483647 else @intCast(seconds * 1000);
    return this.waitMs(timeout_ms);
}

/// Waits for either the specified duration in milliseconds or an incoming signal.
pub fn waitMs(this: *Watcher, timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{
        .fd = this.sfd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ret = posix.poll(&fds, timeout_ms) catch return false;
    if (ret > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
        var info: linux.signalfd_siginfo = undefined;
        _ = posix.read(this.sfd, mem.asBytes(&info)) catch {};
        return true;
    }

    return false;
}

test "Watcher wake on signal" {
    var watcher: Watcher = try .init();
    defer watcher.deinit();

    const woke_early = watcher.waitMs(10);
    try testing.expect(!woke_early);

    try posix.raise(posix.SIG.USR1);
    const woke_by_signal = watcher.waitMs(1000);
    try testing.expect(woke_by_signal);

    try posix.raise(@fromBackingInt(@intCast(35)));
    const woke_by_rtsig = watcher.waitMs(1000);
    try testing.expect(woke_by_rtsig);
}
