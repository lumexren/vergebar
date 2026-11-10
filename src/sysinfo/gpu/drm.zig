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

const Backend = @This();

pub const GPUError = @import("GPUError.zig").GPUError;
pub const GPUInfo = @import("GPUInfo.zig");
pub const GPUMemoryInfo = @import("GPUMemoryInfo.zig");

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const Io = std.Io;
const Dir = Io.Dir;

io: ?Io = null,
card_index: ?u8 = null,
device_name: [96]u8 = @splat(0),
device_name_len: usize = 0,

pub inline fn init(_: anytype) Backend {
    return .{};
}

pub fn shutdown(this: *Backend) void {
    this.* = .{};
}

pub fn initialize(this: *Backend, io: Io, requested_card: ?u32) !void {
    this.io = io;

    if (requested_card) |rc| {
        if (rc > 255) return GPUError.DeviceNotFound;
        const card_u8: u8 = @intCast(rc);
        var path_buf: [64]u8 = undefined;
        const dev_path = mem.print(&path_buf, "/sys/class/drm/card{d}/device", .{card_u8}) catch return GPUError.DeviceNotFound;
        var dir = Dir.openDirAbsolute(io, dev_path, .{}) catch return GPUError.DeviceNotFound;
        dir.close(io);
        this.card_index = card_u8;
        this.detectName(io, card_u8);
        return;
    }

    var best_card: ?u8 = null;
    var idx: u8 = 0;
    while (idx < 8) : (idx += 1) {
        var path_buf: [64]u8 = undefined;
        const dev_path = mem.print(&path_buf, "/sys/class/drm/card{d}/device", .{idx}) catch continue;
        var dir = Dir.openDirAbsolute(io, dev_path, .{}) catch continue;
        dir.close(io);

        if (best_card == null) best_card = idx;

        var test_buf: [128]u8 = undefined;
        const busy_path = mem.print(&test_buf, "{s}/gpu_busy_percent", .{dev_path}) catch "";
        if (readSysfsU64(io, busy_path) != null) {
            best_card = idx;
            break;
        }

        const intel_act = mem.print(&test_buf, "{s}/drm/card{d}/gt_act_freq_mhz", .{ dev_path, idx }) catch "";
        if (readSysfsU64(io, intel_act) != null) {
            best_card = idx;
            break;
        }
    }

    if (best_card) |card| {
        this.card_index = card;
        this.detectName(io, card);
        return;
    }

    return GPUError.NoDevices;
}

pub fn getInfo(this: *Backend) !GPUInfo {
    const card = this.card_index orelse return GPUError.NoDevices;
    const io = this.io orelse return GPUError.NoDevices;

    var path_buf: [128]u8 = undefined;
    const base_path = mem.print(&path_buf, "/sys/class/drm/card{d}/device", .{card}) catch return GPUError.NoDevices;

    var info: GPUInfo = .{
        .backend_name = "DRM",
    };

    if (this.device_name_len > 0) {
        info.setName(this.device_name[0..this.device_name_len]);
    }

    var file_buf: [128]u8 = undefined;
    if (readSysfsU64(io, mem.print(&file_buf, "{s}/gpu_busy_percent", .{base_path}) catch "")) |busy| {
        info.gpu_busy = busy;
    } else {
        const act = readSysfsU64(io, mem.print(&file_buf, "{s}/drm/card{d}/gt_act_freq_mhz", .{ base_path, card }) catch "") orelse readSysfsU64(io, mem.print(&file_buf, "{s}/gt/gt0/act_freq_mhz", .{base_path}) catch "");
        const max = readSysfsU64(io, mem.print(&file_buf, "{s}/drm/card{d}/gt_max_freq_mhz", .{ base_path, card }) catch "") orelse readSysfsU64(io, mem.print(&file_buf, "{s}/gt/gt0/max_freq_mhz", .{base_path}) catch "");
        if (act != null and max != null and max.? > 0) {
            info.gpu_busy = @min(100, (act.? * 100) / max.?);
            info.clock_speed = act.?;
        }
    }

    if (readSysfsU64(io, mem.print(&file_buf, "{s}/mem_info_vram_total", .{base_path}) catch "")) |total| {
        info.memory_info.total = total;
        if (readSysfsU64(io, mem.print(&file_buf, "{s}/mem_info_vram_used", .{base_path}) catch "")) |used| {
            info.memory_info.used = used;
            info.memory_info.free = total -| used;
        }
    }

    var hwmon_idx: u8 = 0;
    while (hwmon_idx < 8) : (hwmon_idx += 1) {
        const temp_raw = readSysfsU64(io, mem.print(&file_buf, "{s}/hwmon/hwmon{d}/temp1_input", .{ base_path, hwmon_idx }) catch "") orelse continue;
        info.temperature = @as(f32, @floatFromInt(temp_raw)) / 1000.0;

        if (readSysfsU64(io, mem.print(&file_buf, "{s}/hwmon/hwmon{d}/pwm1", .{ base_path, hwmon_idx }) catch "")) |pwm_val| {
            info.pwm = @min(100, (pwm_val * 100) / 255);
        }

        if (readSysfsU64(io, mem.print(&file_buf, "{s}/hwmon/hwmon{d}/power1_average", .{ base_path, hwmon_idx }) catch "") orelse readSysfsU64(io, mem.print(&file_buf, "{s}/hwmon/hwmon{d}/power1_input", .{ base_path, hwmon_idx }) catch "")) |pwr_uW| {
            info.power_usage = @as(f32, @floatFromInt(pwr_uW)) / 1_000_000.0;
        }

        break;
    }

    return info;
}

fn detectName(this: *Backend, io: Io, card: u8) void {
    var path_buf: [128]u8 = undefined;
    const uevent_path = mem.print(&path_buf, "/sys/class/drm/card{d}/device/uevent", .{card}) catch return;

    var file = Dir.openFileAbsolute(io, uevent_path, .{ .mode = .read_only }) catch {
        const fallback = mem.print(&this.device_name, "Card {d}", .{card}) catch return;
        this.device_name_len = fallback.len;
        return;
    };
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.readSliceShort(&buf) catch 0;
    const content = buf[0..bytes];

    var driver_name: ?[]const u8 = null;
    var it = mem.tokenizeScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (mem.startsWith(u8, line, "DRIVER=")) {
            driver_name = line["DRIVER=".len..];
            break;
        }
    }

    if (driver_name) |drv| {
        if (mem.eql(u8, drv, "amdgpu")) {
            const formatted = mem.print(&this.device_name, "AMD Radeon (card{d})", .{card}) catch return;
            this.device_name_len = formatted.len;
            return;
        } else if (mem.eql(u8, drv, "i915") or mem.eql(u8, drv, "xe")) {
            const formatted = mem.print(&this.device_name, "Intel Graphics (card{d})", .{card}) catch return;
            this.device_name_len = formatted.len;
            return;
        } else {
            const formatted = mem.print(&this.device_name, "{s} (card{d})", .{ drv, card }) catch return;
            this.device_name_len = formatted.len;
            return;
        }
    }

    const formatted = mem.print(&this.device_name, "Card {d}", .{card}) catch return;
    this.device_name_len = formatted.len;
}

fn readSysfsU64(io: Io, path: []const u8) ?u64 {
    if (path.len == 0) return null;
    var file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var buf: [32]u8 = undefined;
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.readSliceShort(&buf) catch return null;
    if (bytes == 0) return null;
    const trimmed = mem.trim(u8, buf[0..bytes], &ascii.whitespace);
    return fmt.parseInt(u64, trimmed, 10) catch null;
}
