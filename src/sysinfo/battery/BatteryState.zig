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

pub const BatteryState = enum(u32) {
    unknown = 0,
    charging = 1,
    discharging = 2,
    empty = 3,
    fully_charged = 4,
    pending_charge = 5,
    pending_discharge = 6,

    pub fn toString(this: BatteryState) [:0]const u8 {
        return switch (this) {
            .charging => "Charging",
            .discharging => "Discharging",
            .empty => "Empty",
            .fully_charged => "Full",
            .pending_charge => "Pending charge",
            .pending_discharge => "Pending discharge",
            .unknown => "Unknown",
        };
    }
};
