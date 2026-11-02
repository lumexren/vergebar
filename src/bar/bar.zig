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
const Io = std.Io;
const debug = std.debug;
const gtk = @import("gtk");
const config_pkg = @import("utils").Config;
const BarConfig = config_pkg.BarConfig;
const modules = @import("../modules/root.zig");
const DEFAULT_CSS = config_pkg.DEFAULT_STYLE;

pub const Bar = struct {
    allocator: Allocator,
    window: ?*gtk.GtkWidget,
    active_modules: ArrayList(modules.ModuleHandle),

    pub fn create(io: Io, allocator: Allocator, config: *BarConfig, monitor: ?*gtk.GdkMonitor, style_path: ?[]const u8) !*Bar {
        const self = try allocator.create(Bar);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .window = gtk.gtk_window_new(),
            .active_modules = .empty,
        };

        const win = self.window orelse return error.WindowCreationFailed;

        gtk.gtk_layer_init_for_window(@ptrCast(win));
        gtk.gtk_layer_set_namespace(@ptrCast(win), "vergebar");
        gtk.gtk_layer_set_layer(@ptrCast(win), config.layer.toGtk());

        if (monitor) |m| gtk.gtk_layer_set_monitor(@ptrCast(win), m);

        const is_horizontal = config.position == .top or config.position == .bottom;
        switch (config.position) {
            .top => {
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_TOP, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_LEFT, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_RIGHT, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_BOTTOM, 0);
            },
            .bottom => {
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_BOTTOM, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_LEFT, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_RIGHT, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_TOP, 0);
            },
            .left => {
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_LEFT, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_TOP, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_BOTTOM, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_RIGHT, 0);
            },
            .right => {
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_RIGHT, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_TOP, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_BOTTOM, 1);
                gtk.gtk_layer_set_anchor(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_LEFT, 0);
            },
        }

        gtk.gtk_layer_set_margin(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_TOP, config.margin_top);
        gtk.gtk_layer_set_margin(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_BOTTOM, config.margin_bottom);
        gtk.gtk_layer_set_margin(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_LEFT, config.margin_left);
        gtk.gtk_layer_set_margin(@ptrCast(win), gtk.GTK_LAYER_SHELL_EDGE_RIGHT, config.margin_right);

        if (config.exclusive) {
            gtk.gtk_layer_auto_exclusive_zone_enable(@ptrCast(win));
        } else {
            gtk.gtk_layer_set_exclusive_zone(@ptrCast(win), 0);
        }

        if (config.passthrough) gtk.gtk_layer_set_keyboard_mode(@ptrCast(win), gtk.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);

        if (config.height) |h| {
            gtk.gtk_window_set_default_size(@ptrCast(win), 0, h);
            gtk.gtk_widget_set_size_request(win, -1, h);
        }

        if (config.width) |w| {
            gtk.gtk_window_set_default_size(@ptrCast(win), w, 0);
            gtk.gtk_widget_set_size_request(win, w, -1);
        }

        gtk.gtk_widget_set_name(win, "waybar");
        gtk.gtk_widget_add_css_class(win, "vergebar");
        gtk.gtk_widget_add_css_class(win, "vlybar");
        if (config.name) |custom_name| {
            var name_z: [128]u8 = undefined;
            const n_len = @min(custom_name.len, name_z.len - 1);
            @memcpy(name_z[0..n_len], custom_name[0..n_len]);
            name_z[n_len] = 0;
            gtk.gtk_widget_add_css_class(win, @ptrCast(&name_z));
        }

        const orientation: c_uint = if (is_horizontal) gtk.GTK_ORIENTATION_HORIZONTAL else gtk.GTK_ORIENTATION_VERTICAL;
        const center_box = gtk.gtk_center_box_new();
        gtk.gtk_widget_set_valign(center_box, gtk.GTK_ALIGN_CENTER);

        const left_box = gtk.gtk_box_new(orientation, config.spacing);
        gtk.gtk_widget_set_name(left_box, "modules-left");
        gtk.gtk_widget_add_css_class(left_box, "modules-left");
        gtk.gtk_widget_set_valign(left_box, gtk.GTK_ALIGN_CENTER);

        const middle_box = gtk.gtk_box_new(orientation, config.spacing);
        gtk.gtk_widget_set_name(middle_box, "modules-center");
        gtk.gtk_widget_add_css_class(middle_box, "modules-center");
        gtk.gtk_widget_set_valign(middle_box, gtk.GTK_ALIGN_CENTER);

        const right_box = gtk.gtk_box_new(orientation, config.spacing);
        gtk.gtk_widget_set_name(right_box, "modules-right");
        gtk.gtk_widget_add_css_class(right_box, "modules-right");
        gtk.gtk_widget_set_valign(right_box, gtk.GTK_ALIGN_CENTER);

        gtk.gtk_center_box_set_start_widget(@ptrCast(center_box), left_box);
        if (!config.no_center) gtk.gtk_center_box_set_center_widget(@ptrCast(center_box), middle_box);
        gtk.gtk_center_box_set_end_widget(@ptrCast(center_box), right_box);

        gtk.gtk_window_set_child(@ptrCast(win), center_box);

        for (config.modules_left) |mod_name| {
            if (modules.createModule(io, allocator, mod_name, config)) |m| {
                if (m.widget) |w| gtk.gtk_box_append(@ptrCast(left_box), w);
                try self.active_modules.append(allocator, m);
            }
        }

        if (!config.no_center) {
            for (config.modules_center) |mod_name| {
                if (modules.createModule(io, allocator, mod_name, config)) |m| {
                    if (m.widget) |w| gtk.gtk_box_append(@ptrCast(middle_box), w);
                    try self.active_modules.append(allocator, m);
                }
            }
        }

        for (config.modules_right) |mod_name| {
            if (modules.createModule(io, allocator, mod_name, config)) |m| {
                if (m.widget) |w| gtk.gtk_box_append(@ptrCast(right_box), w);
                try self.active_modules.append(allocator, m);
            }
        }

        loadCss(style_path, config.reload_style_on_change);

        if (!config.start_hidden) gtk.gtk_window_present(@ptrCast(win));

        return self;
    }

    pub fn toggleVisibility(self: *Bar) void {
        if (self.window) |win| {
            const is_vis = gtk.gtk_widget_get_visible(win) != 0;
            gtk.gtk_widget_set_visible(win, if (is_vis) 0 else 1);
        }
    }

    pub fn show(self: *Bar) void {
        if (self.window) |win| gtk.gtk_widget_set_visible(win, 1);
    }

    pub fn hide(self: *Bar) void {
        if (self.window) |win| gtk.gtk_widget_set_visible(win, 0);
    }

    pub fn deinit(self: *Bar) void {
        for (self.active_modules.items) |m| m.deinit();
        self.active_modules.deinit(self.allocator);
        if (self.window) |win| gtk.gtk_window_destroy(@ptrCast(win));
        self.allocator.destroy(self);
    }
};

var global_css_provider: ?*gtk.GtkCssProvider = null;
var global_file_monitor: ?*gtk.GFileMonitor = null;
var monitored_style_path: [512]u8 = undefined;

fn onStyleFileChanged(monitor: ?*gtk.GFileMonitor, file: ?*gtk.GFile, other_file: ?*gtk.GFile, event_type: c_int, user_data: gtk.gpointer) callconv(.c) void {
    _ = monitor;
    _ = file;
    _ = other_file;
    _ = user_data;
    if (event_type == 0 or event_type == 1 or event_type == 3) {
        if (global_css_provider) |prov| {
            debug.print("Style file changed on disk, live reloading CSS...\n", .{});
            gtk.gtk_css_provider_load_from_path(prov, @ptrCast(&monitored_style_path));
        }
    }
}

pub fn loadCss(style_path: ?[]const u8, enable_hot_reload: bool) void {
    const display = gtk.gdk_display_get_default() orelse return;

    if (global_css_provider == null) {
        global_css_provider = gtk.gtk_css_provider_new();
        if (global_css_provider) |prov| gtk.gtk_style_context_add_provider_for_display(display, @ptrCast(prov), gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    }

    const provider = global_css_provider orelse return;

    if (style_path) |path| {
        const len = @min(path.len, monitored_style_path.len - 1);
        @memcpy(monitored_style_path[0..len], path[0..len]);
        monitored_style_path[len] = 0;
        gtk.gtk_css_provider_load_from_path(provider, @ptrCast(&monitored_style_path));

        if (enable_hot_reload and global_file_monitor == null) {
            const gfile = gtk.g_file_new_for_path(@ptrCast(&monitored_style_path));
            if (gfile) |gf| {
                global_file_monitor = gtk.g_file_monitor_file(gf, 0, null, null);
                if (global_file_monitor) |mon| {
                    _ = gtk.g_signal_connect_data(mon, "changed", @ptrCast(&onStyleFileChanged), null, null, 0);
                    debug.print("Live CSS hot reload enabled for: {s}\n", .{monitored_style_path[0..len]});
                }
            }
        }
    } else {
        gtk.gtk_css_provider_load_from_string(provider, DEFAULT_CSS.ptr);
    }
}
