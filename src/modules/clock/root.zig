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

const ClockModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;

base: *BaseModule,
format: [:0]const u8,
interval_sec: u32,
timer_id: u32 = 0,
popover: ?*gtk.GtkWidget = null,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*ClockModule {
    const this = try allocator.create(ClockModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "clock", settings);
    errdefer this.base.deinit();

    const raw_fmt = settings.getString("format") orelse "  %H:%M:%S";
    const sanitized = try sanitizeClockFormat(allocator, raw_fmt);
    defer allocator.free(sanitized);

    this.format = try allocator.dupeSentinel(u8, sanitized, 0);
    this.interval_sec = @intCast(settings.getInt("interval") orelse 1);
    this.popover = null;

    if (this.base.on_click == null) {
        this.base.custom_click_handler = &onClick;
        this.base.custom_click_data = this;
    }

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *ClockModule) void {
    const alloc = this.base.allocator;
    if (this.timer_id != 0) _ = gtk.g_source_remove(this.timer_id);
    if (this.popover) |p| {
        gtk.gtk_widget_unparent(p);
        this.popover = null;
    }
    alloc.free(this.format);
    this.base.deinit();
    alloc.destroy(this);
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    const this: *ClockModule = @ptrCast(@alignCast(user_data orelse return false));
    if (btn_num != 1) return false;

    if (this.popover == null and this.base.button != null) {
        const popover = gtk.gtk_popover_new();
        if (popover) |p| {
            gtk.gtk_widget_set_parent(p, this.base.button.?);
            const calendar = gtk.gtk_calendar_new();
            if (calendar) |c| {
                gtk.gtk_popover_set_child(p, c);
            }
            this.popover = p;
        }
    }

    if (this.popover) |p| {
        if (gtk.gtk_widget_get_visible(p) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(p));
        } else {
            gtk.gtk_popover_popup(@ptrCast(p));
        }
        return true;
    }
    return false;
}

pub fn update(this: *ClockModule) void {
    const dt = gtk.g_date_time_new_now_local() orelse return;
    defer gtk.g_date_time_unref(dt);

    if (gtk.g_date_time_format(dt, this.format.ptr)) |formatted_ptr| {
        defer gtk.g_free(formatted_ptr);
        this.base.setText(mem.span(formatted_ptr));
    }

    const tt_fmt: [:0]const u8 = "%A, %B %d, %Y";
    if (gtk.g_date_time_format(dt, tt_fmt.ptr)) |tt_ptr| {
        defer gtk.g_free(tt_ptr);
        this.base.setTooltip(mem.span(tt_ptr));
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *ClockModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn sanitizeClockFormat(allocator: Allocator, raw: []const u8) ![]const u8 {
    var out: ArrayList(u8) = try .initCapacity(allocator, raw.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (i + 1 < raw.len and raw[i] == '{' and raw[i + 1] == ':') {
            i += 2;
            continue;
        }
        if (raw[i] == '}') {
            i += 1;
            continue;
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}
