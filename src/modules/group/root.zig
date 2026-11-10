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

const GroupModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const gtk = @import("gtk");
const BarConfig = @import("utils").Config.BarConfig;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const modules_root = @import("../root.zig");

allocator: Allocator,
name: []const u8,
box: ?*gtk.GtkWidget,
revealer: ?*gtk.GtkWidget = null,
revealer_box: ?*gtk.GtkWidget = null,
children: ArrayList(modules_root.ModuleHandle),
is_drawer: bool = false,
click_to_reveal: bool = false,
start_expanded: bool = false,

pub fn create(
    io: Io,
    allocator: Allocator,
    name: []const u8,
    config: *BarConfig,
) !*GroupModule {
    const settings = config.getModuleSettings(name);
    const this = try allocator.create(GroupModule);
    errdefer allocator.destroy(this);

    const orientation_str = settings.getString("orientation") orelse "horizontal";
    const is_vert = mem.eql(u8, orientation_str, "vertical");
    const orientation: c_uint = if (is_vert) gtk.GTK_ORIENTATION_VERTICAL else gtk.GTK_ORIENTATION_HORIZONTAL;

    const main_box = gtk.gtk_box_new(orientation, 2);

    var name_buf: [128]u8 = undefined;
    const len = @min(name.len, name_buf.len - 1);
    @memcpy(name_buf[0..len], name[0..len]);
    for (name_buf[0..len]) |*ch| {
        if (ch.* == '/' or ch.* == '#') ch.* = '-';
    }
    name_buf[len] = 0;

    if (main_box) |b| {
        gtk.gtk_widget_set_name(b, @ptrCast(&name_buf));
        gtk.gtk_widget_add_css_class(b, "group");
        gtk.gtk_widget_add_css_class(b, @ptrCast(&name_buf));
    }

    this.* = .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .box = main_box,
        .children = .empty,
    };

    var has_drawer = false;
    var transition_duration: c_uint = 500;
    var left_to_right = true;
    var click_to_reveal = false;
    var start_expanded = false;

    if (settings.value == .object and settings.value.object.get("drawer") != null) {
        const drw = settings.value.object.get("drawer").?;
        if (drw == .object) {
            has_drawer = true;
            if (drw.object.get("transition-duration")) |dur| {
                if (dur == .integer) transition_duration = @intCast(dur.integer);
            }
            if (drw.object.get("transition-left-to-right")) |ltr| {
                if (ltr == .bool) left_to_right = ltr.bool;
            }
            if (drw.object.get("click-to-reveal")) |ctr| {
                if (ctr == .bool) click_to_reveal = ctr.bool;
            }
            if (drw.object.get("start-expanded")) |se| {
                if (se == .bool) start_expanded = se.bool;
            }
        }
    }

    this.is_drawer = has_drawer;
    this.click_to_reveal = click_to_reveal;
    this.start_expanded = start_expanded;

    if (has_drawer) {
        const rev = gtk.gtk_revealer_new();
        const rev_box = gtk.gtk_box_new(orientation, 2);

        const trans_type: c_uint = if (is_vert)
            gtk.GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN
        else if (left_to_right)
            gtk.GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT
        else
            gtk.GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT;

        gtk.gtk_revealer_set_transition_type(@ptrCast(rev), trans_type);
        gtk.gtk_revealer_set_transition_duration(@ptrCast(rev), transition_duration);
        gtk.gtk_revealer_set_child(@ptrCast(rev), rev_box);
        gtk.gtk_widget_add_css_class(rev, "drawer");

        if (start_expanded) {
            gtk.gtk_revealer_set_reveal_child(@ptrCast(rev), 1);
        } else {
            gtk.gtk_revealer_set_reveal_child(@ptrCast(rev), 0);
        }

        this.revealer = rev;
        this.revealer_box = rev_box;
    }

    var mod_names: ArrayList([]const u8) = .empty;
    defer mod_names.deinit(allocator);

    if (settings.value == .object and settings.value.object.get("modules") != null) {
        const mods = settings.value.object.get("modules").?;
        if (mods == .array) {
            for (mods.array.items) |m| {
                if (m == .string) {
                    try mod_names.append(allocator, m.string);
                }
            }
        }
    }

    var first_widget: ?*gtk.GtkWidget = null;

    for (mod_names.items, 0..) |child_name, idx| {
        if (modules_root.createModule(io, allocator, child_name, config)) |mod_handle| {
            try this.children.append(allocator, mod_handle);
            if (mod_handle.widget) |w| {
                if (has_drawer) {
                    if (idx == 0) {
                        first_widget = w;
                        if (main_box) |b| gtk.gtk_box_append(@ptrCast(b), w);
                        if (this.revealer) |rev| {
                            if (main_box) |b| gtk.gtk_box_append(@ptrCast(b), rev);
                        }
                    } else {
                        if (this.revealer_box) |rb| gtk.gtk_box_append(@ptrCast(rb), w);
                    }
                } else {
                    if (main_box) |b| gtk.gtk_box_append(@ptrCast(b), w);
                }
            }
        }
    }

    if (has_drawer and main_box != null) {
        if (!click_to_reveal) {
            const motion = gtk.gtk_event_controller_motion_new();
            _ = gtk.g_signal_connect_data(
                motion,
                "enter",
                @ptrCast(&onMotionEnter),
                this,
                null,
                0,
            );
            _ = gtk.g_signal_connect_data(
                motion,
                "leave",
                @ptrCast(&onMotionLeave),
                this,
                null,
                0,
            );
            gtk.gtk_widget_add_controller(main_box.?, @ptrCast(motion));
        } else {
            const click = gtk.gtk_gesture_click_new();
            _ = gtk.g_signal_connect_data(
                click,
                "pressed",
                @ptrCast(&onDrawerClicked),
                this,
                null,
                0,
            );
            const target_widget = first_widget orelse main_box.?;
            gtk.gtk_widget_add_controller(target_widget, @ptrCast(click));
        }
    }

    return this;
}

pub fn deinit(this: *GroupModule) void {
    for (this.children.items) |child| {
        child.deinit();
    }
    this.children.deinit(this.allocator);
    this.allocator.free(this.name);
    this.allocator.destroy(this);
}

fn onMotionEnter(
    controller: ?*anyopaque,
    x: f64,
    y: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = controller;
    _ = x;
    _ = y;
    const this: *GroupModule = @ptrCast(@alignCast(user_data orelse return));
    if (this.revealer) |rev| {
        gtk.gtk_revealer_set_reveal_child(@ptrCast(rev), 1);
        if (this.box) |b| gtk.gtk_widget_add_css_class(b, "expanded");
    }
}

fn onMotionLeave(
    controller: ?*anyopaque,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = controller;
    const this: *GroupModule = @ptrCast(@alignCast(user_data orelse return));
    if (this.revealer) |rev| {
        gtk.gtk_revealer_set_reveal_child(@ptrCast(rev), 0);
        if (this.box) |b| gtk.gtk_widget_remove_css_class(b, "expanded");
    }
}

fn onDrawerClicked(
    gesture: ?*anyopaque,
    n_press: c_int,
    x: f64,
    y: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = gesture;
    _ = n_press;
    _ = x;
    _ = y;
    const this: *GroupModule = @ptrCast(@alignCast(user_data orelse return));
    if (this.revealer) |rev| {
        const is_open = gtk.gtk_revealer_get_reveal_child(@ptrCast(rev)) != 0;
        const new_state: gtk.gboolean = if (is_open) 0 else 1;
        gtk.gtk_revealer_set_reveal_child(@ptrCast(rev), new_state);
        if (this.box) |b| {
            if (new_state != 0) {
                gtk.gtk_widget_add_css_class(b, "expanded");
            } else {
                gtk.gtk_widget_remove_css_class(b, "expanded");
            }
        }
    }
}
