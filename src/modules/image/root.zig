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

const ImageModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const sh = @import("utils").sh;

base: *BaseModule,
allocator: Allocator,
path: ?[]const u8,
exec_cmd: ?[:0]const u8,
size: i32,
image_widget: ?*gtk.GtkWidget,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*ImageModule {
    const this = try allocator.create(ImageModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "image", settings);
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

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .path = if (img_path) |p| try allocator.dupe(u8, p) else null,
        .exec_cmd = if (exec_str) |e| try allocator.dupeSentinel(u8, e, 0) else null,
        .size = size_i,
        .image_widget = img,
    };

    this.update();
    if (interval_i > 0) {
        this.timer_id = gtk.g_timeout_add_seconds(interval_i, @ptrCast(&onTimeout), this);
    }

    return this;
}

pub fn deinit(this: *ImageModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    if (this.path) |p| this.allocator.free(p);
    if (this.exec_cmd) |e| this.allocator.free(e);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *ImageModule) void {
    const img = this.image_widget orelse return;

    var target_path: ?[]const u8 = this.path;
    var exec_buf: [512]u8 = undefined;

    if (this.exec_cmd) |cmd| {
        const len = sh.runBuf(this.base.io, cmd, &exec_buf);
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

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *ImageModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
