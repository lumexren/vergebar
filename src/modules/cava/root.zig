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

const CavaModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const fs = std.fs;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const env = @import("utils").env;

base: *BaseModule,
allocator: Allocator,
bars: u32,
hide_on_silence: bool,
format_silent: []const u8,
icons: ArrayList([]const u8),
timer_id: u32 = 0,
fifo_path: ?[]const u8 = null,
ticks: u32 = 0,
is_audio_active: bool = true,

fn isAudioServerActive(io: Io) bool {
    const runtime_dir = env.get("XDG_RUNTIME_DIR") orelse return true;
    var buf: [fs.max_path_bytes]u8 = undefined;

    const pw_path = mem.print(&buf, "{s}/pipewire-0", .{runtime_dir}) catch return true;
    if (Dir.accessAbsolute(io, pw_path, .{})) {
        return true;
    } else |_| {}

    const pulse_path = mem.print(&buf, "{s}/pulse/native", .{runtime_dir}) catch return true;
    if (Dir.accessAbsolute(io, pulse_path, .{})) {
        return true;
    } else |_| {}

    return false;
}

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*CavaModule {
    const this = try allocator.create(CavaModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "cava", settings);
    errdefer base_mod.deinit();

    const bar_count: u32 = if (settings.getInt("bars")) |b| @intCast(b) else 10;
    const hide_silence = settings.getBool("hide_on_silence") orelse false;
    const fmt_silent = settings.getString("format_silent") orelse "";
    const fifo = if (settings.getString("fifo")) |f| try allocator.dupe(u8, f) else null;
    errdefer if (fifo) |f| allocator.free(f);

    var icon_list: ArrayList([]const u8) = .empty;
    if (settings.value == .object and settings.value.object.get("format-icons") != null) {
        const fi = settings.value.object.get("format-icons").?;
        if (fi == .array) {
            for (fi.array.items) |item| {
                if (item == .string) try icon_list.append(allocator, try allocator.dupe(u8, item.string));
            }
        }
    }

    if (icon_list.items.len == 0) {
        const defaults = [_][]const u8{ " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
        for (defaults) |d| try icon_list.append(allocator, try allocator.dupe(u8, d));
    }

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .bars = bar_count,
        .hide_on_silence = hide_silence,
        .format_silent = try allocator.dupe(u8, fmt_silent),
        .icons = icon_list,
        .fifo_path = fifo,
        .is_audio_active = isAudioServerActive(io),
    };

    this.update();
    const framerate: u32 = if (settings.getInt("framerate")) |fr| @intCast(@max(5, @min(60, fr))) else 20;
    const interval_ms: u32 = 1000 / framerate;
    this.timer_id = gtk.g_timeout_add(interval_ms, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *CavaModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    for (this.icons.items) |ic| this.allocator.free(ic);
    this.icons.deinit(this.allocator);
    this.allocator.free(this.format_silent);
    if (this.fifo_path) |fp| this.allocator.free(fp);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *CavaModule) void {
    this.ticks +%= 1;
    // Check server availability every 20 ticks (~1s at 20fps) without spawning any process
    if (this.ticks % 20 == 1) {
        this.is_audio_active = isAudioServerActive(this.base.io);
    }

    if (!this.is_audio_active) {
        if (this.hide_on_silence) {
            if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
        } else {
            if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
            this.base.setText(this.format_silent);
        }
        return;
    }

    if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);

    var output_buf: [256]u8 = undefined;
    const n_levels = this.icons.items.len;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < this.bars and pos < output_buf.len - 8) : (i += 1) {
        const lvl = (i * 3) % n_levels;
        const glyph = this.icons.items[lvl];
        if (pos + glyph.len < output_buf.len) {
            @memcpy(output_buf[pos .. pos + glyph.len], glyph);
            pos += glyph.len;
        } else break;
    }

    this.base.setText(output_buf[0..pos]);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *CavaModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
