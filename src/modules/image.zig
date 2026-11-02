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
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;

const Context = @import("utils").Context;

pub const ImageModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    path: ?[]const u8,
    exec_cmd: ?[:0]const u8,
    size: i32,
    image_widget: ?*gtk.GtkWidget,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*ImageModule {
        const self = try allocator.create(ImageModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "image", settings);
        errdefer base_mod.deinit();

        const img_path = settings.getString("path");
        const exec_str = settings.getString("exec");
        const size_i = @as(i32, @intCast(settings.getInt("size") orelse 24));
        const interval_i = @as(u32, @intCast(settings.getInt("interval") orelse 0));

        const img = gtk.gtk_image_new();
        if (img) |im| {
            gtk.gtk_image_set_pixel_size(@ptrCast(im), size_i);
            if (base_mod.button) |btn| {
                gtk.gtk_button_set_child(btn, im);
            }
        }

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .path = if (img_path) |p| try allocator.dupe(u8, p) else null,
            .exec_cmd = if (exec_str) |e| try allocator.dupeSentinel(u8, e, 0) else null,
            .size = size_i,
            .image_widget = img,
        };

        self.update();
        if (interval_i > 0) {
            self.timer_id = gtk.g_timeout_add_seconds(interval_i, @ptrCast(&onTimeout), self);
        }

        return self;
    }

    pub fn deinit(self: *ImageModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        if (self.path) |p| self.allocator.free(p);
        if (self.exec_cmd) |e| self.allocator.free(e);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *ImageModule) void {
        const img = self.image_widget orelse return;

        var target_path: ?[]const u8 = self.path;
        var exec_buf: [512]u8 = undefined;

        if (self.exec_cmd) |cmd| {
            const len = Context.runShellBuf(cmd, &exec_buf);
            if (len > 0) {
                target_path = mem.trim(u8, exec_buf[0..len], " \r\n\t");
            }
        }

        if (target_path) |tp| {
            var z_path: [512]u8 = undefined;
            const len = @min(tp.len, z_path.len - 1);
            @memcpy(z_path[0..len], tp[0..len]);
            z_path[len] = 0;
            gtk.gtk_image_set_from_file(@ptrCast(img), @ptrCast(&z_path));
        }
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *ImageModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
