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

const BaseModule = @This();

pub const StateThreshold = @import("StateThreshold.zig");
pub const MenuItemActionContext = @import("MenuItemActionContext.zig");

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const gtk = @import("gtk");
const env = @import("utils").env;
const ModuleSettings = @import("utils").Config.ModuleSettings;

io: Io,
allocator: Allocator,
name: []const u8,
id: []const u8,
button: ?*gtk.GtkWidget,
label: ?*gtk.GtkWidget,

on_click: ?[:0]const u8 = null,
on_click_middle: ?[:0]const u8 = null,
on_click_right: ?[:0]const u8 = null,
on_double_click: ?[:0]const u8 = null,
on_triple_click: ?[:0]const u8 = null,
on_click_release: ?[:0]const u8 = null,
on_click_backward: ?[:0]const u8 = null,
on_click_forward: ?[:0]const u8 = null,
on_scroll_up: ?[:0]const u8 = null,
on_scroll_down: ?[:0]const u8 = null,
on_scroll_left: ?[:0]const u8 = null,
on_scroll_right: ?[:0]const u8 = null,

custom_scroll_handler: ?*const fn (user_data: ?*anyopaque, delta_y: f64) void = null,
custom_scroll_data: ?*anyopaque = null,

custom_click_handler: ?*const fn (user_data: ?*anyopaque, button: c_uint) bool = null,
custom_click_data: ?*anyopaque = null,

format_alt: ?[]const u8 = null,
alt_active: bool = false,

states: ArrayList(StateThreshold),
current_state_class: ?[:0]const u8 = null,

menu_trigger: ?[:0]const u8 = null,
menu_popover: ?*gtk.GtkWidget = null,
menu_actions: StringHashMap([:0]const u8),
tooltip_format: ?[]const u8 = null,
tooltip_enabled: bool = true,

pub fn init(io: Io, allocator: Allocator, name: []const u8, css_id: []const u8, on_click_cmd: ?[]const u8, on_click_middle_cmd: ?[]const u8, on_click_right_cmd: ?[]const u8) !*BaseModule {
    const this = try allocator.create(BaseModule);
    errdefer allocator.destroy(this);

    this.* = .{
        .io = io,
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .id = try allocator.dupe(u8, css_id),
        .button = gtk.gtk_button_new(),
        .label = gtk.gtk_label_new(null),
        .on_click = if (on_click_cmd) |cmd| try allocator.dupeSentinel(u8, cmd, 0) else null,
        .on_click_middle = if (on_click_middle_cmd) |cmd| try allocator.dupeSentinel(u8, cmd, 0) else null,
        .on_click_right = if (on_click_right_cmd) |cmd| try allocator.dupeSentinel(u8, cmd, 0) else null,
        .states = .empty,
        .menu_actions = .init(allocator),
    };

    try this.setupWidgets(css_id);
    return this;
}

pub fn initFromSettings(io: Io, allocator: Allocator, name: []const u8, css_id: []const u8, settings: ModuleSettings) !*BaseModule {
    const this = try allocator.create(BaseModule);
    errdefer allocator.destroy(this);

    this.* = .{
        .io = io,
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .id = try allocator.dupe(u8, css_id),
        .button = gtk.gtk_button_new(),
        .label = gtk.gtk_label_new(null),
        .on_click = if (settings.getString("on-click")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_click_middle = if (settings.getString("on-click-middle")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_click_right = if (settings.getString("on-click-right")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_double_click = if (settings.getString("on-double-click")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_triple_click = if (settings.getString("on-triple-click")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_click_release = if (settings.getString("on-click-release")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_click_backward = if (settings.getString("on-click-backward")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_click_forward = if (settings.getString("on-click-forward")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_scroll_up = if (settings.getString("on-scroll-up")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_scroll_down = if (settings.getString("on-scroll-down")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_scroll_left = if (settings.getString("on-scroll-left")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .on_scroll_right = if (settings.getString("on-scroll-right")) |s| try allocator.dupeSentinel(u8, s, 0) else null,
        .format_alt = if (settings.getString("format-alt")) |fa| try allocator.dupe(u8, fa) else null,
        .states = .empty,
        .menu_trigger = if (settings.getString("menu")) |m| try allocator.dupeSentinel(u8, m, 0) else null,
        .menu_actions = .init(allocator),
        .tooltip_format = if (settings.getString("tooltip-format")) |tf| try allocator.dupe(u8, tf) else null,
        .tooltip_enabled = settings.getBool("tooltip") orelse true,
    };

    if (settings.value == .object and settings.value.object.get("menu-actions") != null) {
        const act_val = settings.value.object.get("menu-actions").?;
        if (act_val == .object) {
            var it = act_val.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    const act_cmd = try allocator.dupeSentinel(u8, entry.value_ptr.*.string, 0);
                    const act_key = try allocator.dupe(u8, entry.key_ptr.*);
                    try this.menu_actions.put(act_key, act_cmd);
                }
            }
        }
    }

    if (settings.value == .object and settings.value.object.get("states") != null) {
        const st_val = settings.value.object.get("states").?;
        if (st_val == .object) {
            var it = st_val.object.iterator();
            while (it.next()) |entry| {
                const st_name = try allocator.dupe(u8, entry.key_ptr.*);
                var st_thresh: f64 = 0;
                if (entry.value_ptr.* == .integer) {
                    st_thresh = @floatFromInt(entry.value_ptr.*.integer);
                } else if (entry.value_ptr.* == .float) {
                    st_thresh = entry.value_ptr.*.float;
                }

                try this.states.append(allocator, .{ .name = st_name, .threshold = st_thresh });
            }
        }
    }

    try this.setupWidgets(css_id);

    this.setupMenu(settings.getString("menu-file"));

    return this;
}

fn setupWidgets(this: *BaseModule, css_id: []const u8) !void {
    if (this.button) |btn| {
        gtk.gtk_button_set_has_frame(btn, 0);
        gtk.gtk_widget_add_css_class(btn, "module");

        var buf: [128]u8 = undefined;
        const safe_len = @min(css_id.len, buf.len - 1);
        @memcpy(buf[0..safe_len], css_id[0..safe_len]);
        for (buf[0..safe_len]) |*ch| {
            if (ch.* == '/' or ch.* == '#') ch.* = '-';
        }
        buf[safe_len] = 0;

        gtk.gtk_widget_set_name(btn, @ptrCast(&buf));
        gtk.gtk_widget_add_css_class(btn, @ptrCast(&buf));

        if (this.label) |lbl| {
            gtk.gtk_label_set_use_markup(lbl, 1);
            gtk.gtk_button_set_child(btn, lbl);
        }

        const gesture = gtk.gtk_gesture_click_new();
        gtk.gtk_gesture_single_set_button(gesture, 0);
        _ = gtk.g_signal_connect_data(gesture, "pressed", @ptrCast(&onGesturePressed), this, null, 0);
        _ = gtk.g_signal_connect_data(gesture, "released", @ptrCast(&onGestureReleased), this, null, 0);
        gtk.gtk_widget_add_controller(btn, @ptrCast(gesture));

        const scroll = gtk.gtk_event_controller_scroll_new(gtk.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        _ = gtk.g_signal_connect_data(scroll, "scroll", @ptrCast(&onScrollEvent), this, null, 0);
        gtk.gtk_widget_add_controller(btn, @ptrCast(scroll));
    }
}

pub fn setupMenu(this: *BaseModule, menu_file_opt: ?[]const u8) void {
    const btn = this.button orelse return;

    const pop = gtk.gtk_popover_new();
    if (pop == null) return;
    gtk.gtk_widget_set_parent(pop, btn);
    this.menu_popover = pop;

    const menu_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(menu_box, "menu");

    if (this.menu_actions.count() > 0) {
        var it = this.menu_actions.iterator();
        while (it.next()) |entry| {
            const item_btn = gtk.gtk_button_new();
            gtk.gtk_button_set_has_frame(item_btn, 0);
            gtk.gtk_widget_add_css_class(item_btn, "menu-item");

            const lbl = gtk.gtk_label_new(@ptrCast(entry.key_ptr.*));
            gtk.gtk_button_set_child(item_btn, lbl);

            const item_ctx = this.allocator.create(MenuItemActionContext) catch continue;
            item_ctx.* = .{
                .allocator = this.allocator,
                .popover = pop,
                .cmd = entry.value_ptr.*,
            };

            _ = gtk.g_signal_connect_data(item_btn, "clicked", @ptrCast(&MenuItemActionContext.onClicked), item_ctx, @ptrCast(&MenuItemActionContext.onFree), 0);

            gtk.gtk_box_append(@ptrCast(menu_box), item_btn);
        }
    } else if (menu_file_opt) |mf| {
        var mf_buf: [256]u8 = undefined;
        const expanded = expandPath(mf, &mf_buf);
        const builder = gtk.gtk_builder_new();
        if (builder) |b| {
            defer gtk.g_object_unref(b);
            var err: ?*anyopaque = null;
            var z_path: [256]u8 = undefined;
            const path_len = @min(expanded.len, z_path.len - 1);
            @memcpy(z_path[0..path_len], expanded[0..path_len]);
            z_path[path_len] = 0;

            _ = gtk.gtk_builder_add_from_file(b, @ptrCast(&z_path), &err);
        }
    }

    gtk.gtk_popover_set_child(@ptrCast(pop), menu_box);
}

pub fn showMenu(this: *BaseModule) void {
    if (this.menu_popover) |pop| gtk.gtk_popover_popup(@ptrCast(pop));
}

pub fn deinit(this: *BaseModule) void {
    if (this.menu_popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.menu_popover = null;
    }

    var act_it = this.menu_actions.iterator();
    while (act_it.next()) |entry| {
        this.allocator.free(entry.key_ptr.*);
        this.allocator.free(entry.value_ptr.*);
    }
    this.menu_actions.deinit();

    if (this.menu_trigger) |mt| this.allocator.free(mt);
    if (this.tooltip_format) |tf| this.allocator.free(tf);

    if (this.on_click) |cmd| this.allocator.free(cmd);
    if (this.on_click_middle) |cmd| this.allocator.free(cmd);
    if (this.on_click_right) |cmd| this.allocator.free(cmd);
    if (this.on_double_click) |cmd| this.allocator.free(cmd);
    if (this.on_triple_click) |cmd| this.allocator.free(cmd);
    if (this.on_click_release) |cmd| this.allocator.free(cmd);
    if (this.on_click_backward) |cmd| this.allocator.free(cmd);
    if (this.on_click_forward) |cmd| this.allocator.free(cmd);
    if (this.on_scroll_up) |cmd| this.allocator.free(cmd);
    if (this.on_scroll_down) |cmd| this.allocator.free(cmd);
    if (this.on_scroll_left) |cmd| this.allocator.free(cmd);
    if (this.on_scroll_right) |cmd| this.allocator.free(cmd);
    if (this.format_alt) |fa| this.allocator.free(fa);
    if (this.current_state_class) |sc| this.allocator.free(sc);

    for (this.states.items) |st| this.allocator.free(st.name);
    this.states.deinit(this.allocator);

    this.allocator.free(this.name);
    this.allocator.free(this.id);
    this.allocator.destroy(this);
}

pub fn toggleAlt(this: *BaseModule) bool {
    if (this.format_alt != null) {
        this.alt_active = !this.alt_active;
        return true;
    }

    return false;
}

pub fn applyState(this: *BaseModule, val: f64, is_lower_better: bool) ?[]const u8 {
    var matched: ?[]const u8 = null;

    for (this.states.items) |st| {
        if (is_lower_better) {
            if (val <= st.threshold) matched = st.name;
        } else {
            if (val >= st.threshold) matched = st.name;
        }
    }

    if (this.current_state_class) |old_class| {
        this.removeCssClass(old_class);
        this.allocator.free(old_class);
        this.current_state_class = null;
    }

    if (matched) |m| {
        if (this.allocator.dupeSentinel(u8, m, 0)) |new_class| {
            this.addCssClass(new_class);
            this.current_state_class = new_class;
        } else |_| {}
    }

    return matched;
}

pub fn setText(this: *BaseModule, text: []const u8) void {
    if (this.label) |lbl| {
        var z_buf: [4096]u8 = undefined;
        const len = @min(text.len, z_buf.len - 1);
        @memcpy(z_buf[0..len], text[0..len]);
        z_buf[len] = 0;
        gtk.gtk_label_set_markup(lbl, @ptrCast(&z_buf));
    }
}

pub fn setTooltip(this: *BaseModule, tooltip: ?[]const u8) void {
    if (this.button) |btn| {
        if (!this.tooltip_enabled) {
            gtk.gtk_widget_set_tooltip_markup(btn, null);
            return;
        }

        if (tooltip) |tt| {
            if (tt.len > 0) {
                var z_buf: [8192]u8 = undefined;
                const len = @min(tt.len, z_buf.len - 1);
                @memcpy(z_buf[0..len], tt[0..len]);
                z_buf[len] = 0;
                gtk.gtk_widget_set_tooltip_markup(btn, @ptrCast(&z_buf));
                return;
            }
        }

        gtk.gtk_widget_set_tooltip_markup(btn, null);
    }
}

pub fn setClasses(this: *BaseModule, warning: bool, critical: bool) void {
    if (this.button) |btn| {
        if (warning) {
            gtk.gtk_widget_add_css_class(btn, "warning");
        } else {
            gtk.gtk_widget_remove_css_class(btn, "warning");
        }

        if (critical) {
            gtk.gtk_widget_add_css_class(btn, "critical");
        } else {
            gtk.gtk_widget_remove_css_class(btn, "critical");
        }
    }
}

pub fn addCssClass(this: *BaseModule, class_name: [:0]const u8) void {
    if (this.button) |btn| gtk.gtk_widget_add_css_class(btn, class_name.ptr);
}

pub fn removeCssClass(this: *BaseModule, class_name: [:0]const u8) void {
    if (this.button) |btn| gtk.gtk_widget_remove_css_class(btn, class_name.ptr);
}

fn expandPath(path: []const u8, out_buf: []u8) []const u8 {
    return env.expandHomeBuf(path, out_buf);
}

fn checkMenuTrigger(this: *BaseModule, action_name: []const u8) bool {
    if (this.menu_trigger) |trig| {
        if (mem.eql(u8, trig, action_name)) {
            this.showMenu();
            return true;
        }
    }

    return false;
}

fn onGesturePressed(gesture: ?*gtk.GtkGestureClick, n_press: c_int, x: f64, y: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = x;
    _ = y;
    const this: *BaseModule = @ptrCast(@alignCast(user_data orelse return));
    const btn_num = gtk.gtk_gesture_single_get_current_button(@ptrCast(gesture));

    if (n_press == 2) {
        if (checkMenuTrigger(this, "on-double-click")) return;
        if (this.on_double_click) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return;
        }
    } else if (n_press == 3) {
        if (checkMenuTrigger(this, "on-triple-click")) return;
        if (this.on_triple_click) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return;
        }
    }

    if (this.custom_click_handler) |handler| {
        if (handler(this.custom_click_data, btn_num)) return;
    }

    switch (btn_num) {
        1 => {
            if (checkMenuTrigger(this, "on-click")) return;
            if (this.on_click) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        2 => {
            if (checkMenuTrigger(this, "on-click-middle")) return;
            if (this.on_click_middle) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        3 => {
            if (checkMenuTrigger(this, "on-click-right")) return;
            if (this.on_click_right) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        8 => {
            if (checkMenuTrigger(this, "on-click-backward")) return;
            if (this.on_click_backward) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        9 => {
            if (checkMenuTrigger(this, "on-click-forward")) return;
            if (this.on_click_forward) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        else => {},
    }
}

fn onGestureReleased(gesture: ?*gtk.GtkGestureClick, n_press: c_int, x: f64, y: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = gesture;
    _ = n_press;
    _ = x;
    _ = y;
    const this: *BaseModule = @ptrCast(@alignCast(user_data orelse return));
    if (checkMenuTrigger(this, "on-click-release")) return;
    if (this.on_click_release) |cmd| {
        _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
    }
}

fn onScrollEvent(controller: ?*gtk.GtkEventControllerScroll, dx: f64, dy: f64, user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    _ = controller;
    const this: *BaseModule = @ptrCast(@alignCast(user_data orelse return 0));

    if (this.custom_scroll_handler) |handler| {
        handler(this.custom_scroll_data, dy);
        return 1;
    }

    if (dy < 0) {
        if (this.on_scroll_up) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return 1;
        }
    } else if (dy > 0) {
        if (this.on_scroll_down) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return 1;
        }
    }

    if (dx < 0) {
        if (this.on_scroll_left) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return 1;
        }
    } else if (dx > 0) {
        if (this.on_scroll_right) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return 1;
        }
    }

    return 0;
}
