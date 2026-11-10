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
const DynLib = std.DynLib;
const smi = @import("bindings").amdsmi;

lib: ?DynLib = null,
handle: smi.amdsmi_processor_handle = null,
device_index: u32 = 0,

fn_amdsmi_init: ?*const fn (u64) callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_shut_down: ?*const fn () callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_get_socket_handles: ?*const fn (*u32, ?[*]smi.amdsmi_socket_handle) callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_get_processor_handles: ?*const fn (smi.amdsmi_socket_handle, *u32, ?[*]smi.amdsmi_processor_handle) callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_get_temp_metric: ?*const fn (smi.amdsmi_processor_handle, smi.amdsmi_temperature_type_t, smi.amdsmi_temperature_metric_t, *i64) callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_get_gpu_busy_percent: ?*const fn (smi.amdsmi_processor_handle, *u32) callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_get_gpu_memory_total: ?*const fn (smi.amdsmi_processor_handle, smi.amdsmi_memory_type_t, *u64) callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_get_gpu_memory_usage: ?*const fn (smi.amdsmi_processor_handle, smi.amdsmi_memory_type_t, *u64) callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_get_gpu_fan_speed: ?*const fn (smi.amdsmi_processor_handle, u32, *i64) callconv(.c) smi.amdsmi_status_t = null,
fn_amdsmi_get_gpu_fan_speed_max: ?*const fn (smi.amdsmi_processor_handle, u32, *u64) callconv(.c) smi.amdsmi_status_t = null,

pub inline fn init(_: anytype) Backend {
    return .{};
}

pub fn shutdown(this: *Backend) void {
    if (this.fn_amdsmi_shut_down) |shut| {
        _ = shut();
    }
    if (this.lib) |*l| {
        l.close();
    }
    this.* = .{};
}

pub fn initialize(this: *Backend, device_index: u32) !void {
    var lib = (DynLib.open("libamd_smi.so") catch DynLib.open("libamd_smi.so.1")) catch return GPUError.LibraryNotFound;
    errdefer lib.close();

    const fn_init = lib.lookup(*const fn (u64) callconv(.c) smi.amdsmi_status_t, "amdsmi_init") orelse return GPUError.HandleFailed;
    const fn_shut = lib.lookup(*const fn () callconv(.c) smi.amdsmi_status_t, "amdsmi_shut_down") orelse return GPUError.HandleFailed;
    const fn_sock = lib.lookup(*const fn (*u32, ?[*]smi.amdsmi_socket_handle) callconv(.c) smi.amdsmi_status_t, "amdsmi_get_socket_handles") orelse return GPUError.HandleFailed;
    const fn_proc = lib.lookup(*const fn (smi.amdsmi_socket_handle, *u32, ?[*]smi.amdsmi_processor_handle) callconv(.c) smi.amdsmi_status_t, "amdsmi_get_processor_handles") orelse return GPUError.HandleFailed;
    const fn_temp = lib.lookup(*const fn (smi.amdsmi_processor_handle, smi.amdsmi_temperature_type_t, smi.amdsmi_temperature_metric_t, *i64) callconv(.c) smi.amdsmi_status_t, "amdsmi_get_temp_metric") orelse return GPUError.HandleFailed;
    const fn_busy = lib.lookup(*const fn (smi.amdsmi_processor_handle, *u32) callconv(.c) smi.amdsmi_status_t, "amdsmi_get_gpu_busy_percent") orelse return GPUError.HandleFailed;
    const fn_mtot = lib.lookup(*const fn (smi.amdsmi_processor_handle, smi.amdsmi_memory_type_t, *u64) callconv(.c) smi.amdsmi_status_t, "amdsmi_get_gpu_memory_total") orelse return GPUError.HandleFailed;
    const fn_musg = lib.lookup(*const fn (smi.amdsmi_processor_handle, smi.amdsmi_memory_type_t, *u64) callconv(.c) smi.amdsmi_status_t, "amdsmi_get_gpu_memory_usage") orelse return GPUError.HandleFailed;
    const fn_fan = lib.lookup(*const fn (smi.amdsmi_processor_handle, u32, *i64) callconv(.c) smi.amdsmi_status_t, "amdsmi_get_gpu_fan_speed") orelse return GPUError.HandleFailed;
    const fn_fmax = lib.lookup(*const fn (smi.amdsmi_processor_handle, u32, *u64) callconv(.c) smi.amdsmi_status_t, "amdsmi_get_gpu_fan_speed_max") orelse return GPUError.HandleFailed;

    if (fn_init(smi.AMDSMI_INIT_AMD_GPUS) != smi.AMDSMI_STATUS_SUCCESS) return GPUError.InitFailed;
    errdefer _ = fn_shut();

    var socket_count: u32 = 0;
    _ = fn_sock(&socket_count, null);
    if (socket_count == 0) return GPUError.NoDevices;

    var sockets: [8]smi.amdsmi_socket_handle = undefined;
    const max_sockets: u32 = @min(socket_count, sockets.len);
    var actual_sockets: u32 = max_sockets;
    _ = fn_sock(&actual_sockets, &sockets);

    var proc_count: u32 = 0;
    _ = fn_proc(sockets[0], &proc_count, null);
    if (proc_count == 0) return GPUError.NoDevices;
    if (device_index >= proc_count) return GPUError.DeviceNotFound;

    var procs: [8]smi.amdsmi_processor_handle = undefined;
    var actual_procs: u32 = @min(proc_count, procs.len);
    _ = fn_proc(sockets[0], &actual_procs, &procs);

    this.lib = lib;
    this.handle = procs[device_index];
    this.device_index = device_index;

    this.fn_amdsmi_init = fn_init;
    this.fn_amdsmi_shut_down = fn_shut;
    this.fn_amdsmi_get_socket_handles = fn_sock;
    this.fn_amdsmi_get_processor_handles = fn_proc;
    this.fn_amdsmi_get_temp_metric = fn_temp;
    this.fn_amdsmi_get_gpu_busy_percent = fn_busy;
    this.fn_amdsmi_get_gpu_memory_total = fn_mtot;
    this.fn_amdsmi_get_gpu_memory_usage = fn_musg;
    this.fn_amdsmi_get_gpu_fan_speed = fn_fan;
    this.fn_amdsmi_get_gpu_fan_speed_max = fn_fmax;
}

pub fn getInfo(this: *Backend) !GPUInfo {
    const handle = this.handle orelse return GPUError.NoDevices;

    var raw_temp: i64 = 0;
    const temperature: f32 = if (this.fn_amdsmi_get_temp_metric.?(handle, smi.AMDSMI_TEMPERATURE_TYPE_EDGE, smi.AMDSMI_TEMP_CURRENT, &raw_temp) == smi.AMDSMI_STATUS_SUCCESS)
        @floatFromInt(raw_temp)
    else
        0;

    var raw_busy: u32 = 0;
    const gpu_busy: u64 = if (this.fn_amdsmi_get_gpu_busy_percent.?(handle, &raw_busy) == smi.AMDSMI_STATUS_SUCCESS)
        raw_busy
    else
        0;

    var mem_total: u64 = 0;
    var mem_used: u64 = 0;
    _ = this.fn_amdsmi_get_gpu_memory_total.?(handle, smi.AMDSMI_MEM_TYPE_VRAM, &mem_total);
    _ = this.fn_amdsmi_get_gpu_memory_usage.?(handle, smi.AMDSMI_MEM_TYPE_VRAM, &mem_used);

    var info: GPUInfo = .{
        .temperature = temperature,
        .gpu_busy = gpu_busy,
        .pwm = this.fanPwm(handle),
        .memory_info = .{
            .total = mem_total,
            .used = mem_used,
            .free = if (mem_total > mem_used) mem_total - mem_used else 0,
        },
        .backend_name = "AMD-SMI",
    };
    info.setName("AMD Radeon");

    return info;
}

fn fanPwm(this: *Backend, handle: smi.amdsmi_processor_handle) u64 {
    var speed: i64 = 0;
    var max: u64 = 0;

    const speed_ok = this.fn_amdsmi_get_gpu_fan_speed.?(handle, 0, &speed) == smi.AMDSMI_STATUS_SUCCESS;
    const max_ok = this.fn_amdsmi_get_gpu_fan_speed_max.?(handle, 0, &max) == smi.AMDSMI_STATUS_SUCCESS;

    if (!speed_ok or !max_ok or max == 0) return 0;

    const pct = @divTrunc(@as(i128, speed) * 100, @as(i128, max));
    return @min(@as(u64, @intCast(pct)), 100);
}
