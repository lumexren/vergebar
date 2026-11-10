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

const gtk = @import("gtk");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Compositor = @import("../workspaces/Compositor.zig").Compositor;

const TaskItem = @This();

pub const TaskClickContext = struct {
    compositor: Compositor,
    id_str: []const u8,
    allocator: Allocator,
};

button: ?*gtk.GtkWidget,
label: ?*gtk.GtkWidget,
image: ?*gtk.GtkWidget,
id_str: []const u8,
click_ctx: ?*TaskClickContext = null,
