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
const TrayModule = @import("root.zig");

const MenuItemClickContext = @This();

tray: *TrayModule,
service: [:0]const u8,
menu_path: [:0]const u8,
popover: ?*gtk.GtkWidget,
id: i32,

pub fn onClicked(btn: ?*gtk.GtkButton, user_data: gtk.gpointer) callconv(.c) void {
    _ = btn;
    const ctx: *MenuItemClickContext = @ptrCast(@alignCast(user_data orelse return));
    if (ctx.popover) |pop| {
        gtk.gtk_popover_popdown(@ptrCast(pop));
    }

    if (ctx.tray.conn) |c| {
        const param = gtk.g_variant_new_parsed("(%i, 'clicked', <0>, 0)", ctx.id);
        gtk.g_dbus_connection_call(
            c,
            ctx.service.ptr,
            ctx.menu_path.ptr,
            "com.canonical.dbusmenu",
            "Event",
            param,
            null,
            0,
            1000,
            null,
            null,
            null,
        );
    }
}

pub fn onFree(data: gtk.gpointer) callconv(.c) void {
    const ctx: *MenuItemClickContext = @ptrCast(@alignCast(data orelse return));
    ctx.tray.allocator.free(ctx.service);
    ctx.tray.allocator.free(ctx.menu_path);
    ctx.tray.allocator.destroy(ctx);
}
