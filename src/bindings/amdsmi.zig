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

pub const amdsmi_socket_handle = *opaque {};
pub const amdsmi_processor_handle = ?*opaque {};

pub const amdsmi_status_t = c_int;
pub const AMDSMI_STATUS_SUCCESS: amdsmi_status_t = 0;

pub const AMDSMI_INIT_AMD_GPUS: u64 = 1 << 0;

pub const amdsmi_temperature_type_t = c_int;
pub const AMDSMI_TEMPERATURE_TYPE_EDGE: amdsmi_temperature_type_t = 0;

pub const amdsmi_temperature_metric_t = c_int;
pub const AMDSMI_TEMP_CURRENT: amdsmi_temperature_metric_t = 0;

pub const amdsmi_memory_type_t = c_int;
pub const AMDSMI_MEM_TYPE_VRAM: amdsmi_memory_type_t = 0;

pub extern "amd_smi" fn amdsmi_init(flags: u64) amdsmi_status_t;
pub extern "amd_smi" fn amdsmi_shut_down() amdsmi_status_t;

pub extern "amd_smi" fn amdsmi_get_socket_handles(socket_count: *u32, socket_handles: ?[*]amdsmi_socket_handle) amdsmi_status_t;
pub extern "amd_smi" fn amdsmi_get_processor_handles(socket: amdsmi_socket_handle, processor_count: *u32, processor_handles: ?[*]amdsmi_processor_handle) amdsmi_status_t;

pub extern "amd_smi" fn amdsmi_get_temp_metric(processor_handle: amdsmi_processor_handle, sensor_type: amdsmi_temperature_type_t, metric: amdsmi_temperature_metric_t, temperature: *i64) amdsmi_status_t;
pub extern "amd_smi" fn amdsmi_get_gpu_busy_percent(processor_handle: amdsmi_processor_handle, busy_percent: *u32) amdsmi_status_t;

pub extern "amd_smi" fn amdsmi_get_gpu_memory_total(processor_handle: amdsmi_processor_handle, mem_type: amdsmi_memory_type_t, total: *u64) amdsmi_status_t;
pub extern "amd_smi" fn amdsmi_get_gpu_memory_usage(processor_handle: amdsmi_processor_handle, mem_type: amdsmi_memory_type_t, used: *u64) amdsmi_status_t;

pub extern "amd_smi" fn amdsmi_get_gpu_fan_speed(processor_handle: amdsmi_processor_handle, sensor_ind: u32, speed: *i64) amdsmi_status_t;
pub extern "amd_smi" fn amdsmi_get_gpu_fan_speed_max(processor_handle: amdsmi_processor_handle, sensor_ind: u32, max_speed: *u64) amdsmi_status_t;
