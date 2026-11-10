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

const CompositorModeModule = @This();

pub const CompositorModeType = @import("CompositorModeType.zig").CompositorModeType;

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

const sh = @import("utils").sh;
const ipc = @import("utils").ipc;
const queryHyprlandSocket = ipc.queryHyprlandSocket;
const querySwaySocket = ipc.querySwaySocket;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
mode_type: CompositorModeType,
format: []const u8,
timer_id: u32 = 0,
event_fd: posix.fd_t = -1,
event_source_id: c_uint = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings, mode_type: CompositorModeType) !*CompositorModeModule {
    const this = try allocator.create(CompositorModeModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, name, settings);
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

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .mode_type = mode_type,
        .format = try allocator.dupe(u8, format_str),
        .event_fd = -1,
        .event_source_id = 0,
    };

    this.update();

    switch (mode_type) {
        .hyprland_submap, .hyprland_language, .hyprland_windowcount => {
            if (ipc.connectHyprlandEventSocket()) |fd| {
                this.event_fd = fd;
                this.event_source_id = gtk.g_unix_fd_add(
                    fd,
                    gtk.G_IO_IN | gtk.G_IO_HUP | gtk.G_IO_ERR,
                    @ptrCast(&onEventFdReady),
                    this,
                );
            }
        },
        .sway_mode, .sway_language, .sway_scratchpad => {
            if (ipc.connectSwayEventSocket("[\"mode\", \"window\", \"input\"]")) |fd| {
                this.event_fd = fd;
                this.event_source_id = gtk.g_unix_fd_add(
                    fd,
                    gtk.G_IO_IN | gtk.G_IO_HUP | gtk.G_IO_ERR,
                    @ptrCast(&onEventFdReady),
                    this,
                );
            }
        },
        else => {},
    }

    this.timer_id = gtk.g_timeout_add_seconds(5, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *CompositorModeModule) void {
    if (this.event_source_id != 0) {
        _ = gtk.g_source_remove(this.event_source_id);
        this.event_source_id = 0;
    }
    if (this.event_fd >= 0) {
        _ = posix.system.close(this.event_fd);
        this.event_fd = -1;
    }
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *CompositorModeModule) void {
    const replacer = &this.replacer;
    replacer.clear();

    switch (this.mode_type) {
        .hyprland_submap => {
            var submap: []const u8 = "default";
            var submap_alloc: ?[]u8 = null;
            defer if (submap_alloc) |s| this.allocator.free(s);

            if (queryHyprlandSocket(this.allocator, "submap")) |resp| {
                submap_alloc = resp;
                submap = mem.trim(u8, resp, " \r\n\t");
            } else {
                var submap_buf: [64]u8 = undefined;
                const len = sh.runBuf(this.base.io, "hyprctl submap 2>/dev/null", &submap_buf);
                if (len > 0) submap = mem.trim(u8, submap_buf[0..len], " \r\n\t");
            }

            replacer.addKey("mode", submap) catch {};
            replacer.addKey("submap", submap) catch {};
            if (mem.eql(u8, submap, "default") or submap.len == 0) {
                if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
                return;
            } else {
                if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
            }
        },
        .hyprland_language => {
            var lang: []const u8 = "us";
            var lang_alloc: ?[]u8 = null;
            defer if (lang_alloc) |l| this.allocator.free(l);

            if (queryHyprlandSocket(this.allocator, "getoption input:kb_layout")) |resp| {
                lang_alloc = resp;
                if (mem.find(u8, resp, "str: ")) |idx| {
                    lang = mem.trim(u8, resp[idx + 5 ..], " \r\n\t");
                }
            } else {
                var buf: [128]u8 = undefined;
                const len = sh.runBuf(this.base.io, "hyprctl getoption input:kb_layout 2>/dev/null | grep 'str:'", &buf);
                if (len > 0) {
                    const slice = buf[0..len];
                    if (mem.find(u8, slice, "str: ")) |idx| {
                        lang = mem.trim(u8, slice[idx + 5 ..], " \r\n\t");
                    }
                }
            }
            replacer.addKey("language", lang) catch {};
        },
        .hyprland_windowcount => {
            var count: i64 = 0;
            var resp_alloc: ?[]u8 = null;
            defer if (resp_alloc) |r| this.allocator.free(r);

            if (queryHyprlandSocket(this.allocator, "j/activeworkspace")) |resp| {
                resp_alloc = resp;
                if (mem.find(u8, resp, "\"windows\":")) |idx| {
                    const rest = resp[idx + 10 ..];
                    if (mem.find(u8, rest, ":")) |colon_idx| {
                        const trimmed = mem.trim(u8, rest[colon_idx + 1 ..], " \r\n\t,}");
                        var end_idx: usize = 0;
                        while (end_idx < trimmed.len and (trimmed[end_idx] >= '0' and trimmed[end_idx] <= '9')) : (end_idx += 1) {}
                        if (end_idx > 0) {
                            count = fmt.parseInt(i64, trimmed[0..end_idx], 10) catch 0;
                        }
                    }
                }
            } else {
                var buf: [256]u8 = undefined;
                const len = sh.runBuf(this.base.io, "hyprctl activeworkspace -j 2>/dev/null | grep '\"windows\":'", &buf);
                if (len > 0) {
                    const slice = buf[0..len];
                    if (mem.find(u8, slice, ":")) |colon_idx| {
                        const trimmed = mem.trim(u8, slice[colon_idx + 1 ..], " \r\n\t,");
                        count = fmt.parseInt(i64, trimmed, 10) catch 0;
                    }
                }
            }
            replacer.addKeyAny("count", count) catch {};
        },
        .sway_mode => {
            var mode: []const u8 = "default";
            var resp_alloc: ?[]u8 = null;
            defer if (resp_alloc) |r| this.allocator.free(r);

            if (querySwaySocket(this.allocator, 7, "")) |resp| {
                resp_alloc = resp;
                if (mem.find(u8, resp, "\"name\":")) |idx| {
                    const rest = resp[idx + 7 ..];
                    if (mem.findScalar(u8, rest, '"')) |first_q| {
                        const val_start = first_q + 1;
                        if (mem.findScalar(u8, rest[val_start..], '"')) |second_q| {
                            mode = rest[val_start .. val_start + second_q];
                        }
                    }
                }
            } else {
                var buf: [64]u8 = undefined;
                const len = sh.runBuf(this.base.io, "swaymsg -t get_binding_state 2>/dev/null", &buf);
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
            }
            replacer.addKey("mode", mode) catch {};
            if (mem.eql(u8, mode, "default") or mode.len == 0) {
                if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
                return;
            } else {
                if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
            }
        },
        .sway_scratchpad => {
            var count: i64 = 0;
            if (querySwaySocket(this.allocator, 4, "")) |resp| {
                defer this.allocator.free(resp);
                var cnt: i64 = 0;
                var cursor: usize = 0;
                while (cursor < resp.len) {
                    if (mem.find(u8, resp[cursor..], "\"scratchpad_state\"")) |rel| {
                        cnt += 1;
                        cursor += rel + 18;
                    } else break;
                }
                count = cnt;
            } else {
                var buf: [32]u8 = undefined;
                const len = sh.runBuf(this.base.io, "swaymsg -t get_tree 2>/dev/null | grep -c '\"scratchpad_state\"'", &buf);
                if (len > 0) {
                    count = fmt.parseInt(i64, mem.trim(u8, buf[0..len], " \r\n\t"), 10) catch 0;
                }
            }
            replacer.addKeyAny("count", count) catch {};
        },
        .sway_language => {
            var lang: []const u8 = "us";
            var lang_alloc: ?[]u8 = null;
            defer if (lang_alloc) |l| this.allocator.free(l);

            if (querySwaySocket(this.allocator, 100, "")) |resp| {
                defer this.allocator.free(resp);
                if (mem.find(u8, resp, "xkb_active_layout_name")) |idx| {
                    const rest = resp[idx + 22 ..];
                    if (mem.find(u8, rest, ": \"")) |colon_q| {
                        const val_start = colon_q + 3;
                        if (mem.findScalar(u8, rest[val_start..], '"')) |second_q| {
                            lang = this.allocator.dupe(u8, rest[val_start .. val_start + second_q]) catch "us";
                            lang_alloc = @constCast(lang);
                        }
                    }
                }
            } else {
                var buf: [256]u8 = undefined;
                const len = sh.runBuf(this.base.io, "swaymsg -t get_inputs 2>/dev/null | grep -m1 'xkb_active_layout_name'", &buf);
                if (len > 0) {
                    const slice = buf[0..len];
                    if (mem.find(u8, slice, ": \"")) |idx| {
                        const val_start = idx + 3;
                        if (mem.findScalar(u8, slice[val_start..], '"')) |end_q| {
                            lang = slice[val_start .. val_start + end_q];
                        }
                    }
                }
            }
            replacer.addKey("language", lang) catch {};
        },
        .river_mode => {
            var mode: []const u8 = "normal";
            var buf: [64]u8 = undefined;
            const len = sh.runBuf(this.base.io, "riverctl get-mode 2>/dev/null", &buf);
            if (len > 0) mode = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("mode", mode) catch {};
        },
        .river_layout => {
            var layout: []const u8 = "rivertile";
            var buf: [64]u8 = undefined;
            const len = sh.runBuf(this.base.io, "riverctl get-layout 2>/dev/null", &buf);
            if (len > 0) layout = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("layout", layout) catch {};
        },
        .river_window => {
            var title: []const u8 = "";
            var buf: [256]u8 = undefined;
            const len = sh.runBuf(this.base.io, "riverctl get-focused-view 2>/dev/null", &buf);
            if (len > 0) title = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("title", title) catch {};
        },
        .dwl_window => {
            var title: []const u8 = "";
            var buf: [256]u8 = undefined;
            const len = sh.runBuf(this.base.io, "dwl-msg get_active_title 2>/dev/null", &buf);
            if (len > 0) title = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("title", title) catch {};
        },
        .wayfire_window => {
            var title: []const u8 = "";
            var buf: [256]u8 = undefined;
            const len = sh.runBuf(this.base.io, "wayfire-msg get_active_window 2>/dev/null", &buf);
            if (len > 0) title = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("title", title) catch {};
        },
        .mango_keymode => {
            var mode: []const u8 = "default";
            var buf: [64]u8 = undefined;
            const len = sh.runBuf(this.base.io, "mangoc get-keymode 2>/dev/null", &buf);
            if (len > 0) mode = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("mode", mode) catch {};
        },
        .mango_language => {
            var lang: []const u8 = "us";
            var buf: [64]u8 = undefined;
            const len = sh.runBuf(this.base.io, "mangoc get-layout 2>/dev/null", &buf);
            if (len > 0) lang = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("language", lang) catch {};
        },
        .mango_layout => {
            var layout: []const u8 = "tile";
            var buf: [64]u8 = undefined;
            const len = sh.runBuf(this.base.io, "mangoc get-layout-name 2>/dev/null", &buf);
            if (len > 0) layout = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("layout", layout) catch {};
        },
        .mango_window => {
            var title: []const u8 = "";
            var buf: [256]u8 = undefined;
            const len = sh.runBuf(this.base.io, "mangoc get-active-window 2>/dev/null", &buf);
            if (len > 0) title = mem.trim(u8, buf[0..len], " \r\n\t");
            replacer.addKey("title", title) catch {};
        },
        .generic => {},
    }

    const rendered = replacer.render(this.format) catch this.format;
    defer if (rendered.ptr != this.format.ptr) this.allocator.free(rendered);

    this.base.setText(rendered);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *CompositorModeModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onEventFdReady(fd: c_int, condition: gtk.GIOCondition, user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const this: *CompositorModeModule = @ptrCast(@alignCast(user_data orelse return 0));
    if ((condition & (gtk.G_IO_ERR | gtk.G_IO_HUP)) != 0) {
        return 0;
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = posix.system.read(fd, &buf, buf.len);
        if (rc <= 0) break;
    }

    this.update();
    return 1;
}
