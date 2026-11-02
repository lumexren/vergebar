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

pub const nvmlDevice_t = ?*opaque {};

pub const nvmlReturn_t = c_int;
pub const NVML_SUCCESS: nvmlReturn_t = 0;

pub const nvmlTemperatureSensors_t = c_int;
pub const NVML_TEMPERATURE_GPU: nvmlTemperatureSensors_t = 0;

pub const nvmlUtilization_t = extern struct {
    gpu: c_uint,
    memory: c_uint,
};

pub const nvmlMemory_t = extern struct {
    total: u64,
    free: u64,
    used: u64,
};

pub const nvmlClockType_t = c_int;
pub const NVML_CLOCK_GRAPHICS: nvmlClockType_t = 0;

pub extern "nvidia-ml" fn nvmlInit() nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlShutdown() nvmlReturn_t;

pub extern "nvidia-ml" fn nvmlDeviceGetCount(deviceCount: *c_uint) nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlDeviceGetHandleByIndex(index: c_uint, device: *nvmlDevice_t) nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlDeviceGetName(device: nvmlDevice_t, name: [*]u8, length: c_uint) nvmlReturn_t;

pub extern "nvidia-ml" fn nvmlDeviceGetUtilizationRates(device: nvmlDevice_t, utilization: *nvmlUtilization_t) nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlDeviceGetTemperature(device: nvmlDevice_t, sensorType: nvmlTemperatureSensors_t, temp: *c_uint) nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlDeviceGetMemoryInfo(device: nvmlDevice_t, memory: *nvmlMemory_t) nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlDeviceGetFanSpeed(device: nvmlDevice_t, speed: *c_uint) nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlDeviceGetPowerUsage(device: nvmlDevice_t, power: *c_uint) nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlDeviceGetEnforcedPowerLimit(device: nvmlDevice_t, limit: *c_uint) nvmlReturn_t;
pub extern "nvidia-ml" fn nvmlDeviceGetClockInfo(device: nvmlDevice_t, clockType: nvmlClockType_t, clockMHz: *c_uint) nvmlReturn_t;
