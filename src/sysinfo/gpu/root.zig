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

pub const GPUError = @import("GPUError.zig").GPUError;
pub const GPUMemoryInfo = @import("GPUMemoryInfo.zig");
pub const GPUInfo = @import("GPUInfo.zig");
pub const nvml = @import("nvml.zig");
pub const amdsmi = @import("amdsmi.zig");
pub const drm = @import("drm.zig");

const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const testing = std.testing;

pub const BackendType = enum {
    auto,
    nvml,
    amdsmi,
    drm,

    pub fn fromString(str: []const u8) BackendType {
        if (ascii.eqlIgnoreCase(str, "nvml") or ascii.eqlIgnoreCase(str, "nvidia")) {
            return .nvml;
        } else if (ascii.eqlIgnoreCase(str, "amdsmi") or ascii.eqlIgnoreCase(str, "amd") or ascii.eqlIgnoreCase(str, "rocm")) {
            return .amdsmi;
        } else if (ascii.eqlIgnoreCase(str, "drm") or ascii.eqlIgnoreCase(str, "sysfs")) {
            return .drm;
        }
        return .auto;
    }
};

pub const GPU = struct {
    pub const Backend = BackendType;

    backend_type: BackendType = .auto,
    device_index: ?u32 = null,
    io: ?Io = null,
    allocator: ?Allocator = null,

    active_backend: ?ActiveBackend = null,

    const ActiveBackend = union(enum) {
        nvml: nvml,
        amdsmi: amdsmi,
        drm: drm,
    };

    pub fn init(allocator: anytype) GPU {
        const T = @TypeOf(allocator);
        if (T == Allocator) {
            return .{ .allocator = allocator };
        }
        return .{};
    }

    pub fn initWithIo(io: Io, allocator: Allocator) GPU {
        return .{
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn setIo(self: *GPU, io: Io) void {
        self.io = io;
    }

    pub fn setBackend(self: *GPU, backend: BackendType) void {
        self.backend_type = backend;
    }

    pub fn setDeviceIndex(self: *GPU, index: ?u32) void {
        self.device_index = index;
    }

    pub fn initialize(self: *GPU) !void {
        var threaded: Io.Threaded = .init_single_threaded;
        const io = self.io orelse threaded.io();
        const dev_idx = self.device_index orelse 0;

        switch (self.backend_type) {
            .nvml => {
                var backend: nvml = .init(self.allocator);
                try backend.initialize(dev_idx);
                self.active_backend = .{ .nvml = backend };
            },
            .amdsmi => {
                var backend: amdsmi = .init(self.allocator);
                try backend.initialize(dev_idx);
                self.active_backend = .{ .amdsmi = backend };
            },
            .drm => {
                var backend: drm = .init(self.allocator);
                try backend.initialize(io, self.device_index);
                self.active_backend = .{ .drm = backend };
            },
            .auto => {
                var n: nvml = .init(self.allocator);
                if (n.initialize(dev_idx)) |_| {
                    self.active_backend = .{ .nvml = n };
                    return;
                } else |_| {
                    n.shutdown();
                }

                var a: amdsmi = .init(self.allocator);
                if (a.initialize(dev_idx)) |_| {
                    self.active_backend = .{ .amdsmi = a };
                    return;
                } else |_| {
                    a.shutdown();
                }

                var d: drm = .init(self.allocator);
                if (d.initialize(io, self.device_index)) |_| {
                    self.active_backend = .{ .drm = d };
                    return;
                } else |_| {
                    d.shutdown();
                }

                return GPUError.NoDevices;
            },
        }
    }

    pub fn getInfo(self: *GPU) !GPUInfo {
        if (self.active_backend) |*backend| {
            return switch (backend.*) {
                .nvml => |*n| n.getInfo(),
                .amdsmi => |*a| a.getInfo(),
                .drm => |*d| d.getInfo(),
            };
        }
        return GPUError.NoDevices;
    }

    pub fn shutdown(self: *GPU) void {
        if (self.active_backend) |*backend| {
            switch (backend.*) {
                .nvml => |*n| n.shutdown(),
                .amdsmi => |*a| a.shutdown(),
                .drm => |*d| d.shutdown(),
            }
            self.active_backend = null;
        }
    }

    pub fn deinit(self: *GPU) void {
        self.shutdown();
    }
};

pub const SMI = GPU;

test "GPU BackendType fromString" {
    try testing.expectEqual(BackendType.nvml, BackendType.fromString("nvml"));
    try testing.expectEqual(BackendType.nvml, BackendType.fromString("nvidia"));
    try testing.expectEqual(BackendType.amdsmi, BackendType.fromString("amdsmi"));
    try testing.expectEqual(BackendType.amdsmi, BackendType.fromString("amd"));
    try testing.expectEqual(BackendType.drm, BackendType.fromString("drm"));
    try testing.expectEqual(BackendType.auto, BackendType.fromString("auto"));
    try testing.expectEqual(BackendType.auto, BackendType.fromString("unknown"));
}

test "GPUInfo helpers" {
    var info: GPUInfo = .{};
    try testing.expect(info.getName() == null);
    info.setName("GeForce RTX 3060");
    try testing.expectEqualStrings("GeForce RTX 3060", info.getName().?);

    var mem_info: GPUMemoryInfo = .{
        .total = 1000,
        .used = 250,
        .free = 750,
    };
    try testing.expectEqual(@as(u64, 25), mem_info.percentage());
}
