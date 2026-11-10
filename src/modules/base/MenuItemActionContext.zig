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

const MenuItemActionContext = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gtk = @import("gtk");

allocator: Allocator,
popover: ?*gtk.GtkWidget,
cmd: [:0]const u8,

pub fn onFree(data: gtk.gpointer, closure: ?*anyopaque) callconv(.c) void {
    _ = closure;
    const ctx: *MenuItemActionContext = @ptrCast(@alignCast(data orelse return));
    ctx.allocator.destroy(ctx);
}

pub fn onClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const ctx: *MenuItemActionContext = @ptrCast(@alignCast(user_data orelse return));
    if (ctx.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
    _ = gtk.g_spawn_command_line_async(ctx.cmd.ptr, null);
}
