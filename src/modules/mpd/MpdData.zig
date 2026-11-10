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

const MpdData = @This();

state: []const u8 = "stop",
artist: []const u8 = "Unknown",
title: []const u8 = "Unknown",
album: []const u8 = "",
album_artist: []const u8 = "",
elapsed: []const u8 = "0:00",
total: []const u8 = "0:00",
volume: []const u8 = "100",
