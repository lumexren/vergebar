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

/// Measurement unit system used for formatting byte counts and transfer speeds.
pub const Units = enum {
    binary,
    decimal,

    const DECIMAL_BASE: f64 = 1000.0;
    const BINARY_BASE: f64 = 1024.0;

    const DECIMAL_BYTE_UNITS = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    const DECIMAL_SPEED_UNITS = [_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s" };

    const BINARY_BYTE_UNITS = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    const BINARY_SPEED_UNITS = [_][]const u8{ "B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s", "PiB/s" };

    pub fn base(this: Units) f64 {
        return switch (this) {
            .binary => BINARY_BASE,
            .decimal => DECIMAL_BASE,
        };
    }

    pub fn byteUnits(this: Units) []const []const u8 {
        return switch (this) {
            .binary => &BINARY_BYTE_UNITS,
            .decimal => &DECIMAL_BYTE_UNITS,
        };
    }

    pub fn speedUnits(this: Units) []const []const u8 {
        return switch (this) {
            .binary => &BINARY_SPEED_UNITS,
            .decimal => &DECIMAL_SPEED_UNITS,
        };
    }
};
