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

/// Stateful tracker for Memory allocation metrics.
const Memory = @This();

pub const MemoryError = @import("MemoryError.zig").MemoryError;
pub const PhysicalMemoryInfo = @import("PhysicalMemoryInfo.zig");
pub const SwapMemoryInfo = @import("SwapMemoryInfo.zig");

const std = @import("std");
const StaticStringMap = std.StaticStringMap;
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const Dir = Io.Dir;

const KB: u64 = 1024;
const MEMINFO_PATH = "/proc/meminfo";
const MEMINFO_BUFFER_SIZE: usize = 16384;

const Field = enum {
    MemTotal,
    MemFree,
    MemAvailable,
    Buffers,
    Cached,
    Shmem,
    Active,
    Inactive,
    Active_anon,
    Inactive_anon,
    Active_file,
    Inactive_file,
    AnonPages,
    Mapped,
    Slab,
    SReclaimable,
    SUnreclaim,
    KReclaimable,
    KernelStack,
    PageTables,
    SecPageTables,
    Percpu,
    Dirty,
    Writeback,
    WritebackTmp,
    Unevictable,
    Mlocked,
    AnonHugePages,
    FileHugePages,
    FilePmdMapped,
    ShmemHugePages,
    ShmemPmdMapped,
    Hugetlb,
    Hugepagesize,
    DirectMap4k,
    DirectMap2M,
    DirectMap1G,
    VmallocTotal,
    VmallocUsed,
    VmallocChunk,
    HardwareCorrupted,
    Bounce,
    NFS_Unstable,
    CmaTotal,
    CmaFree,
    Unaccepted,
    Balloon,
    SwapTotal,
    SwapFree,
    SwapCached,
    Zswap,
    Zswapped,
    CommitLimit,
    Committed_AS,
};

const field_map: StaticStringMap(Field) = .initComptime(.{
    .{ "MemTotal", .MemTotal },                   .{ "MemFree", .MemFree },
    .{ "MemAvailable", .MemAvailable },           .{ "Buffers", .Buffers },
    .{ "Cached", .Cached },                       .{ "Shmem", .Shmem },
    .{ "Active", .Active },                       .{ "Inactive", .Inactive },
    .{ "Active(anon)", .Active_anon },            .{ "Inactive(anon)", .Inactive_anon },
    .{ "Active(file)", .Active_file },            .{ "Inactive(file)", .Inactive_file },
    .{ "AnonPages", .AnonPages },                 .{ "Mapped", .Mapped },
    .{ "Slab", .Slab },                           .{ "SReclaimable", .SReclaimable },
    .{ "SUnreclaim", .SUnreclaim },               .{ "KReclaimable", .KReclaimable },
    .{ "KernelStack", .KernelStack },             .{ "PageTables", .PageTables },
    .{ "SecPageTables", .SecPageTables },         .{ "Percpu", .Percpu },
    .{ "Dirty", .Dirty },                         .{ "Writeback", .Writeback },
    .{ "WritebackTmp", .WritebackTmp },           .{ "Unevictable", .Unevictable },
    .{ "Mlocked", .Mlocked },                     .{ "AnonHugePages", .AnonHugePages },
    .{ "FileHugePages", .FileHugePages },         .{ "FilePmdMapped", .FilePmdMapped },
    .{ "ShmemHugePages", .ShmemHugePages },       .{ "ShmemPmdMapped", .ShmemPmdMapped },
    .{ "Hugetlb", .Hugetlb },                     .{ "Hugepagesize", .Hugepagesize },
    .{ "DirectMap4k", .DirectMap4k },             .{ "DirectMap2M", .DirectMap2M },
    .{ "DirectMap1G", .DirectMap1G },             .{ "VmallocTotal", .VmallocTotal },
    .{ "VmallocUsed", .VmallocUsed },             .{ "VmallocChunk", .VmallocChunk },
    .{ "HardwareCorrupted", .HardwareCorrupted }, .{ "Bounce", .Bounce },
    .{ "NFS_Unstable", .NFS_Unstable },           .{ "CmaTotal", .CmaTotal },
    .{ "CmaFree", .CmaFree },                     .{ "Unaccepted", .Unaccepted },
    .{ "Balloon", .Balloon },                     .{ "SwapTotal", .SwapTotal },
    .{ "SwapFree", .SwapFree },                   .{ "SwapCached", .SwapCached },
    .{ "Zswap", .Zswap },                         .{ "Zswapped", .Zswapped },
    .{ "CommitLimit", .CommitLimit },             .{ "Committed_AS", .Committed_AS },
});

io: Io,
percentage: u64 = 0,
physical: PhysicalMemoryInfo = .{},
swap: SwapMemoryInfo = .{},

pub fn init(io: Io) Memory {
    return .{ .io = io };
}

pub fn deinit(self: *Memory) void {
    _ = self;
}

/// Fetches and refreshes memory metrics.
pub fn update(self: *Memory) !void {
    self.percentage = 0;
    self.physical = .{};
    self.swap = .{};

    var buffer: [MEMINFO_BUFFER_SIZE]u8 = undefined;

    var file = try Dir.openFileAbsolute(self.io, MEMINFO_PATH, .{ .mode = .read_only });
    defer file.close(self.io);

    var reader = file.reader(self.io, &.{});
    const n = try reader.interface.readSliceShort(&buffer);

    var lines = mem.splitScalar(u8, buffer[0..n], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon = mem.findScalar(u8, line, ':') orelse continue;
        const field = field_map.get(line[0..colon]) orelse continue;
        const value = try parseValue(mem.trimStart(u8, line[colon + 1 ..], " \t"));

        switch (field) {
            .MemTotal => self.physical.total = value,
            .MemFree => self.physical.free = value,
            .MemAvailable => self.physical.available = value,
            .Buffers => self.physical.buffers = value,
            .Cached => self.physical.cached = value,
            .Shmem => self.physical.shared = value,
            .Active => self.physical.active = value,
            .Inactive => self.physical.inactive = value,
            .Active_anon => self.physical.active_anon = value,
            .Inactive_anon => self.physical.inactive_anon = value,
            .Active_file => self.physical.active_file = value,
            .Inactive_file => self.physical.inactive_file = value,
            .AnonPages => self.physical.anon_pages = value,
            .Mapped => self.physical.mapped = value,
            .Slab => self.physical.slab = value,
            .SReclaimable => self.physical.slab_reclaimable = value,
            .SUnreclaim => self.physical.slab_unreclaimable = value,
            .KReclaimable => self.physical.kernel_reclaimable = value,
            .KernelStack => self.physical.kernel_stack = value,
            .PageTables => self.physical.page_tables = value,
            .SecPageTables => self.physical.sec_page_tables = value,
            .Percpu => self.physical.percpu = value,
            .Dirty => self.physical.dirty = value,
            .Writeback => self.physical.writeback = value,
            .WritebackTmp => self.physical.writeback_tmp = value,
            .Unevictable => self.physical.unevictable = value,
            .Mlocked => self.physical.mlocked = value,
            .AnonHugePages => self.physical.anon_huge_pages = value,
            .FileHugePages => self.physical.file_huge_pages = value,
            .FilePmdMapped => self.physical.file_pmd_mapped = value,
            .ShmemHugePages => self.physical.shmem_huge_pages = value,
            .ShmemPmdMapped => self.physical.shmem_pmd_mapped = value,
            .Hugetlb => self.physical.hugetlb = value,
            .Hugepagesize => self.physical.hugepages_size = value,
            .DirectMap4k => self.physical.direct_map_4k = value,
            .DirectMap2M => self.physical.direct_map_2m = value,
            .DirectMap1G => self.physical.direct_map_1g = value,
            .VmallocTotal => self.physical.vmalloc_total = value,
            .VmallocUsed => self.physical.vmalloc_used = value,
            .VmallocChunk => self.physical.vmalloc_chunk = value,
            .HardwareCorrupted => self.physical.hardware_corrupted = value,
            .Bounce => self.physical.bounce = value,
            .NFS_Unstable => self.physical.nfs_unstable = value,
            .CmaTotal => self.physical.cma_total = value,
            .CmaFree => self.physical.cma_free = value,
            .Unaccepted => self.physical.unaccepted = value,
            .Balloon => self.physical.balloon = value,
            .SwapTotal => self.swap.total = value,
            .SwapFree => self.swap.free = value,
            .SwapCached => self.swap.cached = value,
            .Zswap => self.swap.zswap = value,
            .Zswapped => self.swap.zswapped = value,
            .CommitLimit => self.swap.commit_limit = value,
            .Committed_AS => self.swap.committed_as = value,
        }
    }

    if (self.physical.available == 0 and self.physical.total != 0) {
        self.physical.available = @min(self.physical.free + self.physical.buffers + self.physical.cached, self.physical.total);
    }

    if (self.physical.total >= self.physical.available) {
        self.physical.used = self.physical.total - self.physical.available;
    }

    if (self.swap.total >= self.swap.free) {
        self.swap.used = self.swap.total - self.swap.free;
    }

    const grand_total = self.physical.total + self.swap.total;
    if (grand_total != 0) {
        self.percentage = @intFromFloat(@as(f64, @floatFromInt(self.physical.used + self.swap.used)) / @as(f64, @floatFromInt(grand_total)) * 100.0);
    }
}

inline fn parseValue(s: []const u8) !u64 {
    var it = mem.tokenizeAny(u8, s, " \t");
    const num = it.next() orelse return MemoryError.InvalidData;
    const value = try fmt.parseUnsigned(u64, num, 10);

    return if (it.next()) |u| if (mem.eql(u8, u, "kB")) value * KB else value else value;
}
