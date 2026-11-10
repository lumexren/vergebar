---
name: vergebar-sysinfo-collector
description: >-
  Implement zero-overhead system metric readers via Linux /proc, /sys, and posix
  file descriptors in pure Zig.
---

# Vergebar Sysinfo Metric Collector Skill

Use this procedure when collecting hardware or system metrics (CPU, RAM, Disks, Network, Battery, Thermals).

## 1. Zero-Overhead Rules
1. Never spawn shell subprocesses (`cat`, `awk`, `grep`, `sh`, `bash`) to read `/sys` or `/proc`.
2. Use `std.Io` with stack-allocated buffers and direct reads via `sysfs.readFile` or `Dir.openFileAbsolute`.
3. Keep allocations to an absolute minimum or zero in the steady-state update cycle.

## 2. Standard Pattern: Reading `/sys` or `/proc`
```zig
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;
const fmt = std.fmt;

pub fn readMetric(io: Io, path: []const u8) ?u64 {
    var buf: [64]u8 = undefined;
    var file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const bytes_read = reader.interface.readSliceShort(&buf) catch return null;
    if (bytes_read == 0) return null;

    const trimmed = mem.trim(u8, buf[0..bytes_read], " \r\n\t");
    return fmt.parseInt(u64, trimmed, 10) catch null;
}
```
