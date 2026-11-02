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

/// Binary unit multipliers (IEC standard: 1024-based)
pub const KiB: f64 = 1024.0;
pub const MiB: f64 = KiB * 1024.0;
pub const GiB: f64 = MiB * 1024.0;
pub const TiB: f64 = GiB * 1024.0;

/// Decimal unit multipliers (SI standard: 1000-based)
pub const kB: f64 = 1000.0;
pub const MB: f64 = kB * 1000.0;
pub const GB: f64 = MB * 1000.0;
pub const TB: f64 = GB * 1000.0;

/// Size units for disk space formatting.
/// Supports both SI (decimal, 1000-based) and IEC (binary, 1024-based) units.
pub const SizeUnit = enum {
    B,
    kB,
    KiB,
    MB,
    MiB,
    GB,
    GiB,
    TB,
    TiB,

    /// Returns the divisor for converting bytes to this unit.
    pub fn divisor(self: @This()) f64 {
        return switch (self) {
            .B => 1.0,
            .kB => kB,
            .KiB => KiB,
            .MB => MB,
            .MiB => MiB,
            .GB => GB,
            .GiB => GiB,
            .TB => TB,
            .TiB => TiB,
        };
    }

    /// Returns the string suffix for this unit.
    pub fn suffix(self: @This()) []const u8 {
        return @tagName(self);
    }
};
