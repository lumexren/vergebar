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

pub const CPU = @import("cpu/root.zig");
pub const disk = @import("disk/root.zig");
pub const Memory = @import("memory/root.zig");
pub const Fan = @import("fan/root.zig");
pub const network = @import("network/root.zig");
pub const Updates = @import("updates/root.zig");
pub const gpu = @import("gpu/root.zig");
pub const GPU = @import("gpu/root.zig").GPU;
pub const mpris = @import("mpris/root.zig");
pub const battery = @import("battery/root.zig");
pub const Backlight = @import("backlight/root.zig");
pub const bluetooth = @import("bluetooth/root.zig");
pub const Pipewire = @import("pipewire/root.zig");
pub const pipewire = Pipewire;
pub const Temperature = @import("temperature/root.zig");
pub const load = @import("load/root.zig");
pub const common = @import("common/root.zig");

test {
    _ = @import("std").testing.refAllDecls(@This());
    _ = @import("cpu/root.zig");
    _ = @import("disk/root.zig");
    _ = @import("memory/root.zig");
    _ = @import("fan/root.zig");
    _ = @import("network/root.zig");
    _ = @import("network/lib.zig");
    _ = @import("updates/root.zig");
    _ = @import("gpu/root.zig");
    _ = @import("mpris/root.zig");
    _ = @import("battery/root.zig");
    _ = @import("backlight/root.zig");
    _ = @import("bluetooth/root.zig");
    _ = @import("load/root.zig");
    _ = @import("pipewire/root.zig");
    _ = @import("temperature/root.zig");
}
