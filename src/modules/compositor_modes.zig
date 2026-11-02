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
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

const Context = @import("utils").Context;

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

pub const CompositorModeModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    mode_type: CompositorModeType,
    format: []const u8,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings, mode_type: CompositorModeType) !*CompositorModeModule {
        const self = try allocator.create(CompositorModeModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, name, settings);
        errdefer base_mod.deinit();

        const default_fmt = switch (mode_type) {
            .hyprland_submap, .sway_mode, .river_mode, .mango_keymode => "{mode}",
            .hyprland_language, .sway_language, .mango_language => "{language}",
            .hyprland_windowcount => "{count}",
            .sway_scratchpad => "{count}",
            .river_layout, .mango_layout => "{layout}",
            .river_window, .dwl_window, .wayfire_window, .mango_window => "{title}",
            .generic => "{}",
        };

        const format_str = settings.getString("format") orelse default_fmt;

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .mode_type = mode_type,
            .format = try allocator.dupe(u8, format_str),
        };

        self.update();
        self.timer_id = gtk.g_timeout_add_seconds(1, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *CompositorModeModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *CompositorModeModule) void {
        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        switch (self.mode_type) {
            .hyprland_submap => {
                var submap_buf: [64]u8 = undefined;
                var submap: []const u8 = "default";
                const len = Context.runShellBuf("hyprctl submap 2>/dev/null", &submap_buf);
                if (len > 0) submap = mem.trim(u8, submap_buf[0..len], " \r\n\t");

                replacer.addKey("mode", submap) catch {};
                replacer.addKey("submap", submap) catch {};
                if (mem.eql(u8, submap, "default") or submap.len == 0) {
                    if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
                    return;
                } else {
                    if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
                }
            },
            .hyprland_language => {
                var lang: []const u8 = "us";
                var buf: [128]u8 = undefined;
                const len = Context.runShellBuf("hyprctl getoption input:kb_layout 2>/dev/null | grep 'str:'", &buf);
                if (len > 0) {
                    const slice = buf[0..len];
                    if (mem.find(u8, slice, "str: ")) |idx| {
                        lang = mem.trim(u8, slice[idx + 5 ..], " \r\n\t");
                    }
                }
                replacer.addKey("language", lang) catch {};
            },
            .hyprland_windowcount => {
                var count: i64 = 0;
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("hyprctl activeworkspace -j 2>/dev/null | grep '\"windows\":'", &buf);
                if (len > 0) {
                    const slice = buf[0..len];
                    if (mem.find(u8, slice, ":")) |colon_idx| {
                        const trimmed = mem.trim(u8, slice[colon_idx + 1 ..], " \r\n\t,");
                        count = fmt.parseInt(i64, trimmed, 10) catch 0;
                    }
                }
                replacer.addKeyAny("count", count) catch {};
            },
            .sway_mode => {
                var mode: []const u8 = "default";
                var buf: [64]u8 = undefined;
                const len = Context.runShellBuf("swaymsg -t get_binding_state 2>/dev/null", &buf);
                if (len > 0) {
                    const slice = buf[0..len];
                    if (mem.find(u8, slice, "\"name\":")) |idx| {
                        const rest = slice[idx + 7 ..];
                        if (mem.findScalar(u8, rest, '"')) |first_q| {
                            const val_start = first_q + 1;
                            if (mem.findScalar(u8, rest[val_start..], '"')) |second_q| {
                                mode = rest[val_start .. val_start + second_q];
                            }
                        }
                    }
                }
                replacer.addKey("mode", mode) catch {};
                if (mem.eql(u8, mode, "default") or mode.len == 0) {
                    if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
                    return;
                } else {
                    if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
                }
            },
            .sway_scratchpad => {
                var count: i64 = 0;
                var buf: [32]u8 = undefined;
                const len = Context.runShellBuf("swaymsg -t get_tree 2>/dev/null | grep -c '\"scratchpad_state\"'", &buf);
                if (len > 0) {
                    count = fmt.parseInt(i64, mem.trim(u8, buf[0..len], " \r\n\t"), 10) catch 0;
                }
                replacer.addKeyAny("count", count) catch {};
            },
            .sway_language => {
                var lang: []const u8 = "us";
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("swaymsg -t get_inputs 2>/dev/null | grep -m1 'xkb_active_layout_name'", &buf);
                if (len > 0) {
                    const slice = buf[0..len];
                    if (mem.find(u8, slice, ": \"")) |idx| {
                        const val_start = idx + 3;
                        if (mem.findScalar(u8, slice[val_start..], '"')) |end_q| {
                            lang = slice[val_start .. val_start + end_q];
                        }
                    }
                }
                replacer.addKey("language", lang) catch {};
            },
            .river_mode => {
                var mode: []const u8 = "normal";
                var buf: [64]u8 = undefined;
                const len = Context.runShellBuf("riverctl get-mode 2>/dev/null", &buf);
                if (len > 0) mode = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("mode", mode) catch {};
            },
            .river_layout => {
                var layout: []const u8 = "rivertile";
                var buf: [64]u8 = undefined;
                const len = Context.runShellBuf("riverctl get-layout 2>/dev/null", &buf);
                if (len > 0) layout = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("layout", layout) catch {};
            },
            .river_window => {
                var title: []const u8 = "";
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("riverctl get-focused-view 2>/dev/null", &buf);
                if (len > 0) title = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("title", title) catch {};
            },
            .dwl_window => {
                var title: []const u8 = "";
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("dwl-msg get_active_title 2>/dev/null", &buf);
                if (len > 0) title = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("title", title) catch {};
            },
            .wayfire_window => {
                var title: []const u8 = "";
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("wayfire-msg get_active_window 2>/dev/null", &buf);
                if (len > 0) title = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("title", title) catch {};
            },
            .mango_keymode => {
                var mode: []const u8 = "default";
                var buf: [64]u8 = undefined;
                const len = Context.runShellBuf("mangoc get-keymode 2>/dev/null", &buf);
                if (len > 0) mode = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("mode", mode) catch {};
            },
            .mango_language => {
                var lang: []const u8 = "us";
                var buf: [64]u8 = undefined;
                const len = Context.runShellBuf("mangoc get-layout 2>/dev/null", &buf);
                if (len > 0) lang = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("language", lang) catch {};
            },
            .mango_layout => {
                var layout: []const u8 = "tile";
                var buf: [64]u8 = undefined;
                const len = Context.runShellBuf("mangoc get-layout-name 2>/dev/null", &buf);
                if (len > 0) layout = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("layout", layout) catch {};
            },
            .mango_window => {
                var title: []const u8 = "";
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("mangoc get-active-window 2>/dev/null", &buf);
                if (len > 0) title = mem.trim(u8, buf[0..len], " \r\n\t");
                replacer.addKey("title", title) catch {};
            },
            .generic => {},
        }

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *CompositorModeModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
