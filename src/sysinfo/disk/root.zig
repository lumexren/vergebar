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

pub const DiskError = @import("DiskError.zig").DiskError;
pub const SizeUnit = @import("SizeUnit.zig").SizeUnit;
pub const DiskInfo = @import("DiskInfo.zig");
pub const formatBytes = @import("DiskInfo.zig").formatBytes;
pub const MountedFilesystem = @import("MountedFilesystem.zig");

pub const DiskIOStats = struct {
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    timestamp: i64 = 0,

    pub fn calculateRates(old: DiskIOStats, new: DiskIOStats) struct { read: f64, write: f64, total: f64 } {
        const dt = new.timestamp - old.timestamp;
        if (dt <= 0) return .{ .read = 0.0, .write = 0.0, .total = 0.0 };

        const t: f64 = @floatFromInt(dt);
        const r: f64 = @floatFromInt(new.read_bytes -| old.read_bytes);
        const w: f64 = @floatFromInt(new.write_bytes -| old.write_bytes);

        return .{ .read = r / t, .write = w / t, .total = (r + w) / t };
    }
};

const stfs = @import("bindings").statvfs;

const std = @import("std");
const StaticStringMap = std.StaticStringMap;
const ArrayList = std.ArrayList;
const mem = std.mem;
const ascii = std.ascii;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const posix = std.posix;
const Io = std.Io;
const Threaded = Io.Threaded;
const Dir = Io.Dir;

const MOUNTS_PATH = "/proc/mounts";
const DISKSTATS_PATH = "/proc/diskstats";
const MOUNTS_BUFFER_SIZE = 16 * 1024;

/// Filesystem types to ignore (virtual/pseudo filesystems).
const ignored_fs_types: StaticStringMap(void) = .initComptime(.{
    .{ "cgroup", {} },
    .{ "cgroup2", {} },
    .{ "debugfs", {} },
    .{ "tracefs", {} },
    .{ "devfs", {} },
    .{ "devpts", {} },
    .{ "devtmpfs", {} },
    .{ "ramfs", {} },
    .{ "tmpfs", {} },
    .{ "hugetlbfs", {} },
    .{ "bpf", {} },
    .{ "configfs", {} },
    .{ "efivarfs", {} },
    .{ "mqueue", {} },
    .{ "proc", {} },
    .{ "pstore", {} },
    .{ "securityfs", {} },
    .{ "sysfs", {} },
    .{ "autofs", {} },
    .{ "fuse.portal", {} },
    .{ "fusectl", {} },
    .{ "overlay", {} },
    .{ "binfmt_misc", {} },
    .{ "nsfs", {} },
    .{ "rpc_pipefs", {} },
    .{ "squashfs", {} },
});

/// Returns true if the filesystem type is virtual/pseudo and should be ignored.
pub fn isIgnoredFsType(fs_type: []const u8) bool {
    return ignored_fs_types.has(fs_type);
}

/// Calculates percentage safely, returning 0 if total is 0.
fn calcPercentage(part: u64, total: u64) u8 {
    if (total == 0) return 0;
    return @intCast((part * 100) / total);
}

/// Fetches disk usage information for the specified path.
pub fn fetchDiskInfo(path: []const u8) DiskError!DiskInfo {
    var path_buf: [posix.PATH_MAX]u8 = undefined;

    if (path.len >= path_buf.len) return DiskError.PathTooLong;

    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var stats: stfs.Statfs = undefined;

    if (stfs.statfs(@ptrCast(path_buf[0..path.len :0]), &stats) != 0) return DiskError.StatvfsFailed;

    const frsize: u64 = if (stats.f_frsize > 0) @intCast(stats.f_frsize) else @intCast(stats.f_bsize);
    const blocks: u64 = stats.f_blocks;
    const bfree: u64 = stats.f_bfree;
    const bavail: u64 = stats.f_bavail;
    const files: u64 = stats.f_files;
    const ffree: u64 = stats.f_ffree;

    const total = blocks * frsize;
    const used = (blocks - bfree) * frsize;
    const inodes_used = if (files >= ffree) files - ffree else 0;

    return .{
        .path = path,
        .total = total,
        .free = bavail * frsize,
        .used = used,
        .percentage_used = calcPercentage(blocks - bfree, blocks),
        .percentage_free = calcPercentage(bavail, blocks),
        .block_size = if (stats.f_bsize > 0) @intCast(stats.f_bsize) else 0,
        .fragment_size = frsize,
        .inodes_total = files,
        .inodes_free = ffree,
        .inodes_used = inodes_used,
        .inodes_percentage_used = calcPercentage(inodes_used, files),
    };
}

/// Fetches disk info for the root filesystem ("/").
pub fn fetchRootDiskInfo() DiskError!DiskInfo {
    return fetchDiskInfo("/");
}

/// Fetches disk I/O stats from /proc/diskstats for target device or all physical disks.
pub fn getDiskIOStats(io: Io, target_device: ?[]const u8, timestamp: i64) !DiskIOStats {
    var buffer: [16 * 1024]u8 = undefined;
    var file = try Dir.openFileAbsolute(io, DISKSTATS_PATH, .{ .mode = .read_only });
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const bytes_read = try reader.interface.readSliceShort(&buffer);
    if (bytes_read == 0) return .{ .read_bytes = 0, .write_bytes = 0, .timestamp = timestamp };

    return parseDiskStats(buffer[0..bytes_read], target_device, timestamp);
}

pub fn parseDiskStats(content: []const u8, target_device: ?[]const u8, timestamp: i64) DiskIOStats {
    var lines = mem.splitScalar(u8, content, '\n');
    var total_read_bytes: u64 = 0;
    var total_write_bytes: u64 = 0;

    const clean_target = if (target_device) |td| blk: {
        var t = td;
        if (mem.startsWith(u8, t, "/dev/")) t = t[5..];
        break :blk if (t.len > 0) t else null;
    } else null;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = mem.tokenizeAny(u8, line, " \t");
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        const dev_name = it.next() orelse continue;

        if (clean_target) |t| {
            if (!mem.eql(u8, dev_name, t)) continue;
        } else {
            if (mem.startsWith(u8, dev_name, "loop") or mem.startsWith(u8, dev_name, "zram") or mem.startsWith(u8, dev_name, "dm-")) continue;
            if ((mem.startsWith(u8, dev_name, "sd") or mem.startsWith(u8, dev_name, "vd") or mem.startsWith(u8, dev_name, "hd")) and ascii.isDigit(dev_name[dev_name.len - 1])) continue;
            if (mem.startsWith(u8, dev_name, "nvme") and mem.find(u8, dev_name, "p") != null) continue;
            if (mem.startsWith(u8, dev_name, "mmcblk") and mem.find(u8, dev_name, "p") != null) continue;
        }

        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        const sectors_read_str = it.next() orelse continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        const sectors_written_str = it.next() orelse continue;

        const sectors_read = fmt.parseInt(u64, sectors_read_str, 10) catch continue;
        const sectors_written = fmt.parseInt(u64, sectors_written_str, 10) catch continue;

        total_read_bytes += sectors_read * 512;
        total_write_bytes += sectors_written * 512;

        if (clean_target != null) break;
    }

    return .{
        .read_bytes = total_read_bytes,
        .write_bytes = total_write_bytes,
        .timestamp = timestamp,
    };
}

/// Fetches information about all mounted real filesystems using the provided Io context.
pub fn fetchMountedFilesystemsIo(io: Io, allocator: Allocator) ![]MountedFilesystem {
    var file = Dir.openFileAbsolute(io, MOUNTS_PATH, .{ .mode = .read_only }) catch return DiskError.StatvfsFailed;
    defer file.close(io);

    var buffer: [MOUNTS_BUFFER_SIZE]u8 = undefined;
    const bytes_read = file.readStreaming(io, &.{buffer[0..]}) catch return DiskError.StatvfsFailed;

    var filesystems: ArrayList(MountedFilesystem) = .empty;
    errdefer freeMountedFilesystems(allocator, filesystems.items);

    var lines = mem.splitScalar(u8, buffer[0..bytes_read], '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var fields = mem.tokenizeScalar(u8, line, ' ');
        const device = fields.next() orelse continue;
        const mount_point = fields.next() orelse continue;
        const fs_type = fields.next() orelse continue;

        if (isIgnoredFsType(fs_type)) continue;

        const info = fetchDiskInfo(mount_point) catch continue;

        if (info.total == 0) continue;

        const device_copy = try allocator.dupe(u8, device);
        errdefer allocator.free(device_copy);

        const mount_point_copy = try allocator.dupe(u8, mount_point);
        errdefer allocator.free(mount_point_copy);

        const fs_type_copy = try allocator.dupe(u8, fs_type);
        errdefer allocator.free(fs_type_copy);

        try filesystems.append(allocator, .{
            .device = device_copy,
            .mount_point = mount_point_copy,
            .fs_type = fs_type_copy,
            .disk_info = .{
                .path = mount_point_copy,
                .total = info.total,
                .free = info.free,
                .used = info.used,
                .percentage_used = info.percentage_used,
                .percentage_free = info.percentage_free,
                .block_size = info.block_size,
                .fragment_size = info.fragment_size,
                .inodes_total = info.inodes_total,
                .inodes_free = info.inodes_free,
                .inodes_used = info.inodes_used,
                .inodes_percentage_used = info.inodes_percentage_used,
            },
        });
    }

    return filesystems.toOwnedSlice(allocator);
}

/// Fetches information about all mounted real filesystems.
pub fn fetchMountedFilesystems(allocator: Allocator) ![]MountedFilesystem {
    var threaded: Threaded = .init_single_threaded;
    return fetchMountedFilesystemsIo(threaded.io(), allocator);
}

/// Frees memory allocated by `fetchMountedFilesystems`.
pub fn freeMountedFilesystems(allocator: Allocator, filesystems: []const MountedFilesystem) void {
    for (filesystems) |fs| {
        allocator.free(fs.device);
        allocator.free(fs.mount_point);
        allocator.free(fs.fs_type);
    }
    allocator.free(filesystems);
}

const testing = std.testing;

test "SizeUnit.divisor" {
    const SizeUnitMod = @import("SizeUnit.zig");
    try testing.expectEqual(@as(f64, 1.0), SizeUnit.B.divisor());
    try testing.expectEqual(SizeUnitMod.KiB, SizeUnit.KiB.divisor());
    try testing.expectEqual(SizeUnitMod.MiB, SizeUnit.MiB.divisor());
    try testing.expectEqual(SizeUnitMod.GiB, SizeUnit.GiB.divisor());
    try testing.expectEqual(SizeUnitMod.TiB, SizeUnit.TiB.divisor());
    try testing.expectEqual(SizeUnitMod.kB, SizeUnit.kB.divisor());
    try testing.expectEqual(SizeUnitMod.MB, SizeUnit.MB.divisor());
}

test "SizeUnit.suffix" {
    try testing.expectEqualStrings("B", SizeUnit.B.suffix());
    try testing.expectEqualStrings("KiB", SizeUnit.KiB.suffix());
    try testing.expectEqualStrings("GiB", SizeUnit.GiB.suffix());
}

test "formatBytes" {
    var buf: [32]u8 = undefined;

    try testing.expectEqualStrings("500.0 B", try formatBytes(500, &buf));
    try testing.expectEqualStrings("2.0 KiB", try formatBytes(2048, &buf));
    try testing.expectEqualStrings("5.0 MiB", try formatBytes(5 * 1024 * 1024, &buf));
    try testing.expectEqualStrings("10.0 GiB", try formatBytes(10 * 1024 * 1024 * 1024, &buf));
}

test "DiskInfo unit conversion" {
    const info: DiskInfo = .{
        .total = 1024 * 1024 * 1024,
        .free = 512 * 1024 * 1024,
        .used = 512 * 1024 * 1024,
    };

    try testing.expectApproxEqAbs(@as(f64, 1.0), info.totalInUnit(.GiB), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 512.0), info.freeInUnit(.MiB), 0.01);
}

test "isIgnoredFsType" {
    try testing.expect(isIgnoredFsType("tmpfs"));
    try testing.expect(isIgnoredFsType("sysfs"));
    try testing.expect(isIgnoredFsType("proc"));
    try testing.expect(isIgnoredFsType("cgroup2"));

    try testing.expect(!isIgnoredFsType("ext4"));
    try testing.expect(!isIgnoredFsType("btrfs"));
    try testing.expect(!isIgnoredFsType("xfs"));
    try testing.expect(!isIgnoredFsType("ntfs"));
}

test "fetchDiskInfo - root" {
    const info = fetchDiskInfo("/") catch |err| {
        if (err == DiskError.StatvfsFailed) return;
        return err;
    };

    try testing.expect(info.total > 0);
    try testing.expect(info.total >= info.used);
    try testing.expect(info.percentage_used <= 100);
}

test "fetchDiskInfo - path too long" {
    const long_path = "/" ++ @as([posix.PATH_MAX]u8, @splat('a'));
    try testing.expectError(DiskError.PathTooLong, fetchDiskInfo(long_path));
}

test "fetchMountedFilesystems" {
    const allocator = testing.allocator;

    const filesystems = fetchMountedFilesystems(allocator) catch |err| {
        if (err == DiskError.StatvfsFailed) return;
        return err;
    };
    defer freeMountedFilesystems(allocator, filesystems);
    for (filesystems) |fs| {
        try testing.expect(fs.device.len > 0);
        try testing.expect(fs.mount_point.len > 0);
        try testing.expect(fs.fs_type.len > 0);
        try testing.expect(fs.disk_info.total > 0);
    }
}

test "parseDiskStats and calculateRates" {
    const content =
        \\   8       0 sda 100 0 2000 50 200 0 4000 60 0 10 20
        \\   8       1 sda1 100 0 2000 50 200 0 4000 60 0 10 20
        \\ 259       0 nvme0n1 50 0 1000 20 100 0 2000 30 0 5 10
        \\
    ;

    const sda_stats = parseDiskStats(content, "/dev/sda", 10);
    try testing.expectEqual(@as(u64, 2000 * 512), sda_stats.read_bytes);
    try testing.expectEqual(@as(u64, 4000 * 512), sda_stats.write_bytes);
    try testing.expectEqual(@as(i64, 10), sda_stats.timestamp);

    const all_stats = parseDiskStats(content, null, 10);
    try testing.expectEqual(@as(u64, 3000 * 512), all_stats.read_bytes);
    try testing.expectEqual(@as(u64, 6000 * 512), all_stats.write_bytes);

    const sda_stats_next: DiskIOStats = .{
        .read_bytes = 2000 * 512 + 1024 * 1024,
        .write_bytes = 4000 * 512 + 2 * 1024 * 1024,
        .timestamp = 11,
    };
    const rates = DiskIOStats.calculateRates(sda_stats, sda_stats_next);
    try testing.expectApproxEqAbs(@as(f64, 1024 * 1024), rates.read, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 2 * 1024 * 1024), rates.write, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 3 * 1024 * 1024), rates.total, 1.0);
}
