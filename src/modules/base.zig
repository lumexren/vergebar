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
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const gtk = @import("gtk");
const Context = @import("utils").Context;
const ModuleSettings = @import("utils").Config.ModuleSettings;

pub const StateThreshold = struct {
    name: []const u8,
    threshold: f64,
};

pub const BaseModule = struct {
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

    format_alt: ?[]const u8 = null,
    alt_active: bool = false,

    states: ArrayList(StateThreshold),
    current_state_class: ?[:0]const u8 = null,

    menu_trigger: ?[:0]const u8 = null,
    menu_popover: ?*gtk.GtkWidget = null,
    menu_actions: StringHashMap([:0]const u8),
    tooltip_format: ?[]const u8 = null,
    tooltip_enabled: bool = true,

    pub fn init(allocator: Allocator, name: []const u8, css_id: []const u8, on_click_cmd: ?[]const u8, on_click_middle_cmd: ?[]const u8, on_click_right_cmd: ?[]const u8) !*BaseModule {
        const self = try allocator.create(BaseModule);
        errdefer allocator.destroy(self);

        self.* = .{
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

        try self.setupWidgets(css_id);
        return self;
    }

    pub fn initFromSettings(allocator: Allocator, name: []const u8, css_id: []const u8, settings: ModuleSettings) !*BaseModule {
        const self = try allocator.create(BaseModule);
        errdefer allocator.destroy(self);

        self.* = .{
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
                        try self.menu_actions.put(act_key, act_cmd);
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

                    try self.states.append(allocator, .{ .name = st_name, .threshold = st_thresh });
                }
            }
        }

        try self.setupWidgets(css_id);

        self.setupMenu(settings.getString("menu-file"));

        return self;
    }

    fn setupWidgets(self: *BaseModule, css_id: []const u8) !void {
        if (self.button) |btn| {
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

            if (self.label) |lbl| {
                gtk.gtk_label_set_use_markup(lbl, 1);
                gtk.gtk_button_set_child(btn, lbl);
            }

            const gesture = gtk.gtk_gesture_click_new();
            gtk.gtk_gesture_single_set_button(gesture, 0);
            _ = gtk.g_signal_connect_data(gesture, "pressed", @ptrCast(&onGesturePressed), self, null, 0);
            _ = gtk.g_signal_connect_data(gesture, "released", @ptrCast(&onGestureReleased), self, null, 0);
            gtk.gtk_widget_add_controller(btn, @ptrCast(gesture));

            const scroll = gtk.gtk_event_controller_scroll_new(gtk.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
            _ = gtk.g_signal_connect_data(scroll, "scroll", @ptrCast(&onScrollEvent), self, null, 0);
            gtk.gtk_widget_add_controller(btn, @ptrCast(scroll));
        }
    }

    pub fn setupMenu(self: *BaseModule, menu_file_opt: ?[]const u8) void {
        const btn = self.button orelse return;

        const pop = gtk.gtk_popover_new();
        if (pop == null) return;
        gtk.gtk_widget_set_parent(pop, btn);
        self.menu_popover = pop;

        const menu_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
        gtk.gtk_widget_add_css_class(menu_box, "menu");

        if (self.menu_actions.count() > 0) {
            var it = self.menu_actions.iterator();
            while (it.next()) |entry| {
                const item_btn = gtk.gtk_button_new();
                gtk.gtk_button_set_has_frame(item_btn, 0);
                gtk.gtk_widget_add_css_class(item_btn, "menu-item");

                const lbl = gtk.gtk_label_new(@ptrCast(entry.key_ptr.*));
                gtk.gtk_button_set_child(item_btn, lbl);

                const item_ctx = self.allocator.create(MenuItemActionContext) catch continue;
                item_ctx.* = .{
                    .popover = pop,
                    .cmd = entry.value_ptr.*,
                };

                _ = gtk.g_signal_connect_data(item_btn, "clicked", @ptrCast(&onMenuItemClicked), item_ctx, null, 0);

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

    pub fn showMenu(self: *BaseModule) void {
        if (self.menu_popover) |pop| gtk.gtk_popover_popup(@ptrCast(pop));
    }

    pub fn deinit(self: *BaseModule) void {
        if (self.menu_popover) |pop| {
            gtk.gtk_widget_unparent(pop);
            self.menu_popover = null;
        }

        var act_it = self.menu_actions.iterator();
        while (act_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.menu_actions.deinit();

        if (self.menu_trigger) |mt| self.allocator.free(mt);
        if (self.tooltip_format) |tf| self.allocator.free(tf);

        if (self.on_click) |cmd| self.allocator.free(cmd);
        if (self.on_click_middle) |cmd| self.allocator.free(cmd);
        if (self.on_click_right) |cmd| self.allocator.free(cmd);
        if (self.on_double_click) |cmd| self.allocator.free(cmd);
        if (self.on_triple_click) |cmd| self.allocator.free(cmd);
        if (self.on_click_release) |cmd| self.allocator.free(cmd);
        if (self.on_click_backward) |cmd| self.allocator.free(cmd);
        if (self.on_click_forward) |cmd| self.allocator.free(cmd);
        if (self.on_scroll_up) |cmd| self.allocator.free(cmd);
        if (self.on_scroll_down) |cmd| self.allocator.free(cmd);
        if (self.on_scroll_left) |cmd| self.allocator.free(cmd);
        if (self.on_scroll_right) |cmd| self.allocator.free(cmd);
        if (self.format_alt) |fa| self.allocator.free(fa);
        if (self.current_state_class) |sc| self.allocator.free(sc);

        for (self.states.items) |st| self.allocator.free(st.name);
        self.states.deinit(self.allocator);

        self.allocator.free(self.name);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn toggleAlt(self: *BaseModule) bool {
        if (self.format_alt != null) {
            self.alt_active = !self.alt_active;
            return true;
        }

        return false;
    }

    pub fn applyState(self: *BaseModule, val: f64, is_lower_better: bool) ?[]const u8 {
        var matched: ?[]const u8 = null;

        for (self.states.items) |st| {
            if (is_lower_better) {
                if (val <= st.threshold) matched = st.name;
            } else {
                if (val >= st.threshold) matched = st.name;
            }
        }

        if (self.current_state_class) |old_class| {
            self.removeCssClass(old_class);
            self.allocator.free(old_class);
            self.current_state_class = null;
        }

        if (matched) |m| {
            if (self.allocator.dupeSentinel(u8, m, 0)) |new_class| {
                self.addCssClass(new_class);
                self.current_state_class = new_class;
            } else |_| {}
        }

        return matched;
    }

    pub fn setText(self: *BaseModule, text: []const u8) void {
        if (self.label) |lbl| {
            var z_buf: [4096]u8 = undefined;
            const len = @min(text.len, z_buf.len - 1);
            @memcpy(z_buf[0..len], text[0..len]);
            z_buf[len] = 0;
            gtk.gtk_label_set_markup(lbl, @ptrCast(&z_buf));
        }
    }

    pub fn setTooltip(self: *BaseModule, tooltip: ?[]const u8) void {
        if (self.button) |btn| {
            if (!self.tooltip_enabled) {
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

    pub fn setClasses(self: *BaseModule, warning: bool, critical: bool) void {
        if (self.button) |btn| {
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

    pub fn addCssClass(self: *BaseModule, class_name: [:0]const u8) void {
        if (self.button) |btn| gtk.gtk_widget_add_css_class(btn, class_name.ptr);
    }

    pub fn removeCssClass(self: *BaseModule, class_name: [:0]const u8) void {
        if (self.button) |btn| gtk.gtk_widget_remove_css_class(btn, class_name.ptr);
    }
};

const MenuItemActionContext = struct {
    popover: ?*gtk.GtkWidget,
    cmd: [:0]const u8,
};

fn onMenuItemClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const ctx: *MenuItemActionContext = @ptrCast(@alignCast(user_data orelse return));
    if (ctx.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
    _ = gtk.g_spawn_command_line_async(ctx.cmd.ptr, null);
}

fn expandPath(path: []const u8, out_buf: []u8) []const u8 {
    return Context.expandHomeBuf(path, out_buf);
}

fn checkMenuTrigger(self: *BaseModule, action_name: []const u8) bool {
    if (self.menu_trigger) |trig| {
        if (mem.eql(u8, trig, action_name)) {
            self.showMenu();
            return true;
        }
    }

    return false;
}

fn onGesturePressed(gesture: ?*gtk.GtkGestureClick, n_press: c_int, x: f64, y: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = x;
    _ = y;
    const self: *BaseModule = @ptrCast(@alignCast(user_data orelse return));
    const btn_num = gtk.gtk_gesture_single_get_current_button(@ptrCast(gesture));

    if (n_press == 2) {
        if (checkMenuTrigger(self, "on-double-click")) return;
        if (self.on_double_click) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return;
        }
    } else if (n_press == 3) {
        if (checkMenuTrigger(self, "on-triple-click")) return;
        if (self.on_triple_click) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return;
        }
    }

    switch (btn_num) {
        1 => {
            if (checkMenuTrigger(self, "on-click")) return;
            if (self.on_click) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        2 => {
            if (checkMenuTrigger(self, "on-click-middle")) return;
            if (self.on_click_middle) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        3 => {
            if (checkMenuTrigger(self, "on-click-right")) return;
            if (self.on_click_right) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        8 => {
            if (checkMenuTrigger(self, "on-click-backward")) return;
            if (self.on_click_backward) |cmd| {
                _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            }
        },
        9 => {
            if (checkMenuTrigger(self, "on-click-forward")) return;
            if (self.on_click_forward) |cmd| {
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
    const self: *BaseModule = @ptrCast(@alignCast(user_data orelse return));
    if (checkMenuTrigger(self, "on-click-release")) return;
    if (self.on_click_release) |cmd| {
        _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
    }
}

fn onScrollEvent(controller: ?*gtk.GtkEventControllerScroll, dx: f64, dy: f64, user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    _ = controller;
    const self: *BaseModule = @ptrCast(@alignCast(user_data orelse return 0));

    if (self.custom_scroll_handler) |handler| {
        handler(self.custom_scroll_data, dy);
        return 1;
    }

    if (dy < 0) {
        if (self.on_scroll_up) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return 1;
        }
    } else if (dy > 0) {
        if (self.on_scroll_down) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return 1;
        }
    }

    if (dx < 0) {
        if (self.on_scroll_left) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return 1;
        }
    } else if (dx > 0) {
        if (self.on_scroll_right) |cmd| {
            _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
            return 1;
        }
    }

    return 0;
}
