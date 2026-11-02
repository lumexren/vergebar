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
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Context = @import("utils").Context;

pub const CavaModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    bars: u32,
    hide_on_silence: bool,
    format_silent: []const u8,
    icons: ArrayList([]const u8),
    timer_id: u32 = 0,
    fifo_path: ?[]const u8 = null,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*CavaModule {
        const self = try allocator.create(CavaModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "cava", settings);
        errdefer base_mod.deinit();

        const bar_count: u32 = if (settings.getInt("bars")) |b| @intCast(b) else 10;
        const hide_silence = settings.getBool("hide_on_silence") orelse false;
        const fmt_silent = settings.getString("format_silent") orelse "";

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

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .bars = bar_count,
            .hide_on_silence = hide_silence,
            .format_silent = try allocator.dupe(u8, fmt_silent),
            .icons = icon_list,
        };

        self.update();
        const framerate: u32 = if (settings.getInt("framerate")) |fr| @intCast(@max(5, @min(60, fr))) else 20;
        const interval_ms: u32 = 1000 / framerate;
        self.timer_id = gtk.g_timeout_add(interval_ms, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *CavaModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        for (self.icons.items) |ic| self.allocator.free(ic);
        self.icons.deinit(self.allocator);
        self.allocator.free(self.format_silent);
        if (self.fifo_path) |fp| self.allocator.free(fp);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *CavaModule) void {
        var output_buf: [256]u8 = undefined;

        var pw_buf: [128]u8 = undefined;
        const pw_len = Context.runShellBuf("pw-cli info 0 2>/dev/null", &pw_buf);
        const is_active = pw_len > 0;

        if (!is_active) {
            if (self.hide_on_silence) {
                if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
            } else {
                if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
                self.base.setText(self.format_silent);
            }
            return;
        }

        if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);

        const n_levels = self.icons.items.len;
        var pos: usize = 0;
        var i: usize = 0;
        while (i < self.bars and pos < output_buf.len - 8) : (i += 1) {
            const lvl = (i * 3) % n_levels;
            const glyph = self.icons.items[lvl];
            if (pos + glyph.len < output_buf.len) {
                @memcpy(output_buf[pos .. pos + glyph.len], glyph);
                pos += glyph.len;
            } else break;
        }

        self.base.setText(output_buf[0..pos]);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *CavaModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
