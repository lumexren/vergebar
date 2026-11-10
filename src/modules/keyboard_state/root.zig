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

const KeyboardStateModule = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const json = std.json;
const Io = std.Io;
const posix = std.posix;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const sysfs = @import("utils").sysfs;
const ipc = @import("utils").ipc;
const env = @import("utils").env;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
format: []const u8,
format_icons: ?json.Value,
timer_id: u32 = 0,
event_fd: posix.fd_t = -1,
event_source_id: c_uint = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*KeyboardStateModule {
    const this = try allocator.create(KeyboardStateModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "keyboard-state", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getString("format") orelse "{layout}";

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .format = try allocator.dupe(u8, format_str),
        .format_icons = if (settings.value == .object) settings.value.object.get("format-icons") else null,
        .event_fd = -1,
        .event_source_id = 0,
    };

    if (this.base.button) |btn| {
        const click = gtk.gtk_gesture_click_new();
        _ = gtk.g_signal_connect_data(
            click,
            "pressed",
            @ptrCast(&onLayoutClicked),
            this,
            null,
            0,
        );
        gtk.gtk_widget_add_controller(btn, @ptrCast(click));
    }

    if (ipc.connectHyprlandEventSocket()) |fd| {
        this.event_fd = fd;
        this.event_source_id = gtk.g_unix_fd_add(
            fd,
            gtk.G_IO_IN | gtk.G_IO_HUP | gtk.G_IO_ERR,
            @ptrCast(&onEventFdReady),
            this,
        );
    } else if (ipc.connectSwayEventSocket("[\"input\"]")) |fd| {
        this.event_fd = fd;
        this.event_source_id = gtk.g_unix_fd_add(
            fd,
            gtk.G_IO_IN | gtk.G_IO_HUP | gtk.G_IO_ERR,
            @ptrCast(&onEventFdReady),
            this,
        );
    }

    this.update();
    this.timer_id = gtk.g_timeout_add_seconds(2, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *KeyboardStateModule) void {
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

pub fn update(this: *KeyboardStateModule) void {
    const caps = isLedActive(this.base.io, "capslock");
    const num = isLedActive(this.base.io, "numlock");

    const layout_full = getActiveLayout(this.allocator) orelse "us";
    defer if (!mem.eql(u8, layout_full, "us")) this.allocator.free(layout_full);

    const layout_short = shortenLayout(layout_full);

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKey("layout", layout_short) catch {};
    replacer.addKey("layout_full", layout_full) catch {};
    replacer.addKey("capslock", if (caps) "CAPS" else "") catch {};
    replacer.addKey("numlock", if (num) "NUM" else "") catch {};
    replacer.addKey("name", if (caps) "CAPS" else if (num) "NUM" else layout_short) catch {};
    replacer.addKey("icon", if (caps) "󰬈" else if (num) "󰎦" else "󰌌") catch {};

    const rendered = replacer.render(this.format) catch this.format;
    defer if (rendered.ptr != this.format.ptr) this.allocator.free(rendered);

    this.base.setText(rendered);

    if (caps) this.base.addCssClass("capslock") else this.base.removeCssClass("capslock");
    if (num) this.base.addCssClass("numlock") else this.base.removeCssClass("numlock");

    var tt_buf: [128]u8 = undefined;
    const tt = mem.print(&tt_buf, "Layout: {s} | Caps: {s} | Num: {s}", .{ layout_full, if (caps) "ON" else "OFF", if (num) "ON" else "OFF" }) catch "Keyboard";
    this.base.setTooltip(tt);
}

fn getActiveLayout(allocator: Allocator) ?[]const u8 {
    if (ipc.queryHyprlandSocket(allocator, "j/devices")) |resp| {
        defer allocator.free(resp);
        if (json.parseFromSlice(json.Value, allocator, resp, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("keyboards")) |kbs| {
                    if (kbs == .array) {
                        for (kbs.array.items) |kb| {
                            if (kb == .object) {
                                const is_main = if (kb.object.get("main")) |m| m == .bool and m.bool else false;
                                if (is_main or kbs.array.items.len == 1) {
                                    if (kb.object.get("active_keymap")) |akm| {
                                        if (akm == .string and akm.string.len > 0) {
                                            return allocator.dupe(u8, akm.string) catch null;
                                        }
                                    }
                                }
                            }
                        }
                        for (kbs.array.items) |kb| {
                            if (kb == .object) {
                                if (kb.object.get("active_keymap")) |akm| {
                                    if (akm == .string and akm.string.len > 0) {
                                        return allocator.dupe(u8, akm.string) catch null;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else |_| {}
    }

    if (ipc.querySwaySocket(allocator, 100, "")) |resp| {
        defer allocator.free(resp);
        if (json.parseFromSlice(json.Value, allocator, resp, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .array) {
                for (parsed.value.array.items) |item| {
                    if (item == .object) {
                        if (item.object.get("type")) |t| {
                            if (t == .string and mem.eql(u8, t.string, "keyboard")) {
                                if (item.object.get("xkb_active_layout_name")) |aln| {
                                    if (aln == .string and aln.string.len > 0) {
                                        return allocator.dupe(u8, aln.string) catch null;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else |_| {}
    }

    return null;
}

fn shortenLayout(name: []const u8) []const u8 {
    if (mem.find(u8, name, "Turkish") != null or mem.find(u8, name, "Türkçe") != null) return "TR";
    if (mem.find(u8, name, "(US)") != null or mem.find(u8, name, "US") != null or mem.find(u8, name, "English (US)") != null) return "US";
    if (mem.find(u8, name, "(UK)") != null or mem.find(u8, name, "UK") != null) return "UK";
    if (mem.find(u8, name, "English") != null) return "EN";
    if (mem.find(u8, name, "German") != null or mem.find(u8, name, "Deutsch") != null) return "DE";
    if (mem.find(u8, name, "French") != null or mem.find(u8, name, "Français") != null) return "FR";
    if (mem.find(u8, name, "Spanish") != null or mem.find(u8, name, "Español") != null) return "ES";
    if (mem.find(u8, name, "Russian") != null) return "RU";
    if (mem.find(u8, name, "Arabic") != null) return "AR";
    if (mem.find(u8, name, "Japanese") != null) return "JA";
    if (name.len >= 2) return name[0..2];
    return name;
}

fn cycleKeyboardLayout(allocator: Allocator) void {
    if (ipc.queryHyprlandSocket(allocator, "switchxkblayout all next")) |resp| {
        allocator.free(resp);
        return;
    }
    if (ipc.querySwaySocket(allocator, 0, "input type:keyboard xkb_switch_layout next")) |resp| {
        allocator.free(resp);
        return;
    }
    _ = gtk.g_spawn_command_line_async("niri msg action switch-layout next", null);
}

fn onLayoutClicked(
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
    const this: *KeyboardStateModule = @ptrCast(@alignCast(user_data orelse return));
    cycleKeyboardLayout(this.allocator);
    this.update();
}

fn onEventFdReady(fd: c_int, condition: gtk.GIOCondition, user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const this: *KeyboardStateModule = @ptrCast(@alignCast(user_data orelse return 0));
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

fn isLedActive(io: Io, led_name: []const u8) bool {
    var dir = sysfs.openDirAbsolute(io, "/sys/class/leds", .{ .iterate = true }) catch return false;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (mem.find(u8, entry.name, led_name) != null) {
            var path_buf: [256]u8 = undefined;
            const b_path = mem.print(&path_buf, "/sys/class/leds/{s}/brightness", .{entry.name}) catch continue;
            path_buf[b_path.len] = 0;

            var buf: [16]u8 = undefined;
            if (sysfs.readLine(io, path_buf[0..b_path.len :0], &buf)) |trimmed| {
                if (mem.eql(u8, trimmed, "1") or (!mem.eql(u8, trimmed, "0") and trimmed.len > 0)) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *KeyboardStateModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
