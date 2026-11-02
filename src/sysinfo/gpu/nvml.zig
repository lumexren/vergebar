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
const DynLib = std.DynLib;
const smi = @import("bindings").nvml;

lib: ?DynLib = null,
handle: smi.nvmlDevice_t = null,
device_index: u32 = 0,

fn_nvmlInit: ?*const fn () callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlShutdown: ?*const fn () callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetCount: ?*const fn (*c_uint) callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetHandleByIndex: ?*const fn (c_uint, *smi.nvmlDevice_t) callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetUtilizationRates: ?*const fn (smi.nvmlDevice_t, *smi.nvmlUtilization_t) callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetTemperature: ?*const fn (smi.nvmlDevice_t, smi.nvmlTemperatureSensors_t, *c_uint) callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetMemoryInfo: ?*const fn (smi.nvmlDevice_t, *smi.nvmlMemory_t) callconv(.c) smi.nvmlReturn_t = null,

fn_nvmlDeviceGetName: ?*const fn (smi.nvmlDevice_t, [*]u8, c_uint) callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetFanSpeed: ?*const fn (smi.nvmlDevice_t, *c_uint) callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetPowerUsage: ?*const fn (smi.nvmlDevice_t, *c_uint) callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetEnforcedPowerLimit: ?*const fn (smi.nvmlDevice_t, *c_uint) callconv(.c) smi.nvmlReturn_t = null,
fn_nvmlDeviceGetClockInfo: ?*const fn (smi.nvmlDevice_t, smi.nvmlClockType_t, *c_uint) callconv(.c) smi.nvmlReturn_t = null,

pub inline fn init(_: anytype) Backend {
    return .{};
}

pub fn shutdown(self: *Backend) void {
    if (self.fn_nvmlShutdown) |shut| {
        _ = shut();
    }
    if (self.lib) |*l| {
        l.close();
    }
    self.* = .{};
}

pub fn initialize(self: *Backend, device_index: u32) !void {
    var lib = (DynLib.open("libnvidia-ml.so.1") catch DynLib.open("libnvidia-ml.so")) catch return GPUError.LibraryNotFound;
    errdefer lib.close();

    const fn_init = lib.lookup(*const fn () callconv(.c) smi.nvmlReturn_t, "nvmlInit") orelse return GPUError.HandleFailed;
    const fn_shut = lib.lookup(*const fn () callconv(.c) smi.nvmlReturn_t, "nvmlShutdown") orelse return GPUError.HandleFailed;
    const fn_cnt = lib.lookup(*const fn (*c_uint) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetCount") orelse return GPUError.HandleFailed;
    const fn_hdl = lib.lookup(*const fn (c_uint, *smi.nvmlDevice_t) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetHandleByIndex") orelse return GPUError.HandleFailed;
    const fn_util = lib.lookup(*const fn (smi.nvmlDevice_t, *smi.nvmlUtilization_t) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetUtilizationRates") orelse return GPUError.HandleFailed;
    const fn_temp = lib.lookup(*const fn (smi.nvmlDevice_t, smi.nvmlTemperatureSensors_t, *c_uint) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetTemperature") orelse return GPUError.HandleFailed;
    const fn_mem = lib.lookup(*const fn (smi.nvmlDevice_t, *smi.nvmlMemory_t) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetMemoryInfo") orelse return GPUError.HandleFailed;

    if (fn_init() != smi.NVML_SUCCESS) return GPUError.InitFailed;
    errdefer _ = fn_shut();

    var count: c_uint = 0;
    if (fn_cnt(&count) != smi.NVML_SUCCESS or count == 0) return GPUError.NoDevices;
    if (device_index >= count) return GPUError.DeviceNotFound;

    var handle: smi.nvmlDevice_t = null;
    if (fn_hdl(device_index, &handle) != smi.NVML_SUCCESS) return GPUError.HandleFailed;

    self.lib = lib;
    self.handle = handle;
    self.device_index = device_index;

    self.fn_nvmlInit = fn_init;
    self.fn_nvmlShutdown = fn_shut;
    self.fn_nvmlDeviceGetCount = fn_cnt;
    self.fn_nvmlDeviceGetHandleByIndex = fn_hdl;
    self.fn_nvmlDeviceGetUtilizationRates = fn_util;
    self.fn_nvmlDeviceGetTemperature = fn_temp;
    self.fn_nvmlDeviceGetMemoryInfo = fn_mem;

    self.fn_nvmlDeviceGetName = lib.lookup(*const fn (smi.nvmlDevice_t, [*]u8, c_uint) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetName");
    self.fn_nvmlDeviceGetFanSpeed = lib.lookup(*const fn (smi.nvmlDevice_t, *c_uint) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetFanSpeed");
    self.fn_nvmlDeviceGetPowerUsage = lib.lookup(*const fn (smi.nvmlDevice_t, *c_uint) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetPowerUsage");
    self.fn_nvmlDeviceGetEnforcedPowerLimit = lib.lookup(*const fn (smi.nvmlDevice_t, *c_uint) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetEnforcedPowerLimit");
    self.fn_nvmlDeviceGetClockInfo = lib.lookup(*const fn (smi.nvmlDevice_t, smi.nvmlClockType_t, *c_uint) callconv(.c) smi.nvmlReturn_t, "nvmlDeviceGetClockInfo");
}

pub fn getInfo(self: *Backend) !GPUInfo {
    const handle = self.handle orelse return GPUError.NoDevices;

    var util: smi.nvmlUtilization_t = undefined;
    if (self.fn_nvmlDeviceGetUtilizationRates.?(handle, &util) != smi.NVML_SUCCESS) return GPUError.QueryFailed;

    var raw_temp: c_uint = 0;
    if (self.fn_nvmlDeviceGetTemperature.?(handle, smi.NVML_TEMPERATURE_GPU, &raw_temp) != smi.NVML_SUCCESS) return GPUError.QueryFailed;

    var mem_info: smi.nvmlMemory_t = undefined;
    if (self.fn_nvmlDeviceGetMemoryInfo.?(handle, &mem_info) != smi.NVML_SUCCESS) return GPUError.QueryFailed;

    var info: GPUInfo = .{
        .gpu_busy = util.gpu,
        .temperature = @floatFromInt(raw_temp),
        .memory_info = .{
            .free = mem_info.free,
            .total = mem_info.total,
            .used = mem_info.used,
        },
        .backend_name = "NVML",
    };

    if (self.fn_nvmlDeviceGetName) |getName| {
        var name_buf: [96]u8 = undefined;
        if (getName(handle, &name_buf, name_buf.len) == smi.NVML_SUCCESS) info.setName(mem.sliceTo(&name_buf, 0));
    }

    if (self.fn_nvmlDeviceGetFanSpeed) |getFan| {
        var fan_speed: c_uint = 0;
        if (getFan(handle, &fan_speed) == smi.NVML_SUCCESS) info.pwm = fan_speed;
    }

    if (self.fn_nvmlDeviceGetPowerUsage) |getPwr| {
        var pwr_mw: c_uint = 0;
        if (getPwr(handle, &pwr_mw) == smi.NVML_SUCCESS) info.power_usage = @as(f32, @floatFromInt(pwr_mw)) / 1000.0;
    }

    if (self.fn_nvmlDeviceGetEnforcedPowerLimit) |getLimit| {
        var limit_mw: c_uint = 0;
        if (getLimit(handle, &limit_mw) == smi.NVML_SUCCESS) info.power_limit = @as(f32, @floatFromInt(limit_mw)) / 1000.0;
    }

    if (self.fn_nvmlDeviceGetClockInfo) |getClock| {
        var clock_mhz: c_uint = 0;
        if (getClock(handle, smi.NVML_CLOCK_GRAPHICS, &clock_mhz) == smi.NVML_SUCCESS) info.clock_speed = clock_mhz;
    }

    return info;
}
