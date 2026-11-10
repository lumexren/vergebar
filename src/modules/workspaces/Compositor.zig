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

const std = @import("std");
const mem = std.mem;
const env = @import("utils").env;

pub const Compositor = enum {
    kde,
    hyprland,
    sway,
    niri,
    river,
    dwl,
    wayfire,
    mango,
    generic,

    pub fn name(this: Compositor) []const u8 {
        return switch (this) {
            .kde => "KDE Plasma (KWin)",
            .hyprland => "Hyprland",
            .sway => "Sway / i3",
            .niri => "Niri",
            .river => "River",
            .dwl => "DWL",
            .wayfire => "Wayfire",
            .mango => "Mango",
            .generic => "Generic Wayland",
        };
    }

    pub fn detect(name_hint: []const u8) Compositor {
        if (env.get("HYPRLAND_INSTANCE_SIGNATURE") != null) return .hyprland;
        if (env.get("SWAYSOCK") != null or env.get("I3SOCK") != null) return .sway;
        if (env.get("NIRI_SOCKET") != null) return .niri;
        if (env.get("RIVER_SOCKET") != null) return .river;

        if (env.get("XDG_CURRENT_DESKTOP")) |val| {
            if (mem.find(u8, val, "KDE") != null) return .kde;
        }
        if (env.get("KDE_FULL_SESSION") != null) return .kde;

        if (mem.startsWith(u8, name_hint, "hyprland")) return .hyprland;
        if (mem.startsWith(u8, name_hint, "sway")) return .sway;
        if (mem.startsWith(u8, name_hint, "niri")) return .niri;
        if (mem.startsWith(u8, name_hint, "river")) return .river;
        if (mem.startsWith(u8, name_hint, "dwl")) return .dwl;
        if (mem.startsWith(u8, name_hint, "wayfire")) return .wayfire;
        if (mem.startsWith(u8, name_hint, "mango")) return .mango;

        return .generic;
    }
};
