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

pub const CompositorModeType = enum {
    hyprland_submap,
    hyprland_language,
    hyprland_windowcount,
    sway_mode,
    sway_scratchpad,
    sway_language,
    river_mode,
    river_layout,
    river_window,
    dwl_window,
    wayfire_window,
    mango_keymode,
    mango_language,
    mango_layout,
    mango_window,
    generic,
};
