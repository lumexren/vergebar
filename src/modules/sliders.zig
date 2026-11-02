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
const Io = std.Io;
const gtk = @import("gtk");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Context = @import("utils").Context;

pub const SliderType = enum {
    backlight,
    pulseaudio,
};

pub const SliderModule = struct {
    allocator: Allocator,
    slider_type: SliderType,
    name: []const u8,
    scale: ?*gtk.GtkWidget,
    min_val: f64,
    max_val: f64,
    timer_id: u32 = 0,
    is_updating: bool = false,

    pub fn create(
        allocator: Allocator,
        name: []const u8,
        settings: ModuleSettings,
        slider_type: SliderType,
    ) !*SliderModule {
        const self = try allocator.create(SliderModule);
        errdefer allocator.destroy(self);

        const min_val = settings.getFloat("min") orelse 0.0;
        const max_val = settings.getFloat("max") orelse 100.0;

        const scale = gtk.gtk_scale_new_with_range(gtk.GTK_ORIENTATION_HORIZONTAL, min_val, max_val, 1.0);
        if (scale) |s| {
            gtk.gtk_scale_set_draw_value(@ptrCast(s), 0);
            gtk.gtk_scale_set_has_origin(@ptrCast(s), 1);
            gtk.gtk_widget_set_size_request(s, 100, -1);
            gtk.gtk_widget_add_css_class(s, "slider");
            switch (slider_type) {
                .backlight => gtk.gtk_widget_add_css_class(s, "backlight-slider"),
                .pulseaudio => gtk.gtk_widget_add_css_class(s, "pulseaudio-slider"),
            }
        }

        self.* = .{
            .allocator = allocator,
            .slider_type = slider_type,
            .name = try allocator.dupe(u8, name),
            .scale = scale,
            .min_val = min_val,
            .max_val = max_val,
        };

        if (self.scale) |s| {
            _ = gtk.g_signal_connect_data(
                s,
                "value-changed",
                @ptrCast(&onValueChanged),
                self,
                null,
                0,
            );
        }

        self.update();
        self.timer_id = gtk.g_timeout_add_seconds(2, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *SliderModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn update(self: *SliderModule) void {
        self.is_updating = true;
        defer self.is_updating = false;

        const s = self.scale orelse return;

        switch (self.slider_type) {
            .backlight => {
                const cur = readBacklightPercent();
                gtk.gtk_range_set_value(@ptrCast(s), cur);
            },
            .pulseaudio => {
                const cur = readVolumePercent();
                gtk.gtk_range_set_value(@ptrCast(s), cur);
            },
        }
    }

    pub fn onUserAdjust(self: *SliderModule, val: f64) void {
        if (self.is_updating) return;

        switch (self.slider_type) {
            .backlight => {
                var buf: [64]u8 = undefined;
                const cmd = mem.print(&buf, "brightnessctl set {d:.0}%\x00", .{val}) catch return;
                _ = gtk.g_spawn_command_line_async(@ptrCast(cmd.ptr), null);
            },
            .pulseaudio => {
                var buf: [64]u8 = undefined;
                const ratio = val / 100.0;
                const cmd = mem.print(&buf, "wpctl set-volume @DEFAULT_AUDIO_SINK@ {d:.2}\x00", .{ratio}) catch return;
                _ = gtk.g_spawn_command_line_async(@ptrCast(cmd.ptr), null);
            },
        }
    }
};

fn readBacklightPercent() f64 {
    const ctx = Context.get() orelse return 50.0;
    var dir = Io.Dir.openDirAbsolute(ctx.io, "/sys/class/backlight", .{ .iterate = true }) catch return 50.0;
    defer dir.close(ctx.io);

    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        var dev_buf: [128]u8 = undefined;
        const cur_path = mem.print(&dev_buf, "/sys/class/backlight/{s}/actual_brightness", .{entry.name}) catch continue;
        dev_buf[cur_path.len] = 0;

        var dev_buf2: [128]u8 = undefined;
        const max_path = mem.print(&dev_buf2, "/sys/class/backlight/{s}/max_brightness", .{entry.name}) catch continue;
        dev_buf2[max_path.len] = 0;

        var cur_val: f64 = 0;
        var max_val: f64 = 0;

        var buf: [32]u8 = undefined;
        if (Context.readSysfsLine(dev_buf[0..cur_path.len :0], &buf)) |s| {
            cur_val = fmt.parseFloat(f64, s) catch 0;
        }

        var buf2: [32]u8 = undefined;
        if (Context.readSysfsLine(dev_buf2[0..max_path.len :0], &buf2)) |s| {
            max_val = fmt.parseFloat(f64, s) catch 0;
        }

        if (max_val > 0) {
            return (cur_val / max_val) * 100.0;
        }
    }
    return 50.0;
}

fn readVolumePercent() f64 {
    var buf: [64]u8 = undefined;
    const len = Context.runShellBuf("wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null", &buf);
    if (len > 0) {
        const slice = buf[0..len];
        if (mem.find(u8, slice, "Volume: ")) |idx| {
            const start = idx + "Volume: ".len;
            const end = mem.findScalarPos(u8, slice, start, ' ') orelse len;
            const num_str = mem.trim(u8, slice[start..end], " \r\n\t");
            const val = fmt.parseFloat(f64, num_str) catch 0.5;
            return val * 100.0;
        }
    }
    return 50.0;
}

fn onValueChanged(
    range: ?*gtk.GtkRange,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const self: *SliderModule = @ptrCast(@alignCast(user_data orelse return));
    const val = gtk.gtk_range_get_value(range);
    self.onUserAdjust(val);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *SliderModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
