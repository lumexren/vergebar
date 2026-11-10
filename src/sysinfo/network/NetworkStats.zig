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

/// Network traffic statistics.
const NetworkStats = @This();

rx_bytes: u64,
tx_bytes: u64,
timestamp: i64,

/// Calculate rates (bytes/sec) between two samples.
pub fn calculateRates(old: NetworkStats, new: NetworkStats) struct { download: f64, upload: f64, total: f64 } {
    const dt = new.timestamp - old.timestamp;
    if (dt <= 0) return .{ .download = 0.0, .upload = 0.0, .total = 0.0 };

    const t: f64 = @floatFromInt(dt);
    const rx: f64 = @floatFromInt(new.rx_bytes -| old.rx_bytes);
    const tx: f64 = @floatFromInt(new.tx_bytes -| old.tx_bytes);

    return .{ .download = rx / t, .upload = tx / t, .total = (rx + tx) / t };
}
