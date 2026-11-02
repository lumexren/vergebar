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
const ArrayList = std.ArrayList;
const Io = std.Io;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

pub const WireplumberModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    io: Io,
    format: []const u8,
    format_muted: []const u8,
    format_icons: ArrayList([]const u8),
    max_volume: u32,
    scroll_step: f64,
    timer_id: u32 = 0,

    pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*WireplumberModule {
        const self = try allocator.create(WireplumberModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click") orelse "pavucontrol";
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "wireplumber", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.allocator = allocator;
        self.io = io;
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{icon}  {volume}%");
        self.format_muted = try allocator.dupe(u8, settings.getString("format-muted") orelse "");
        self.max_volume = @intCast(settings.getInt("max-volume") orelse 150);
        self.scroll_step = @floatFromInt(settings.getInt("scroll-step") orelse 5);
        if (self.scroll_step <= 0) self.scroll_step = 5.0;

        self.format_icons = .empty;

        if (settings.value == .object and settings.value.object.get("format-icons") != null) {
            const icons_val = settings.value.object.get("format-icons").?;
            if (icons_val == .object) {
                if (icons_val.object.get("default")) |def_arr| {
                    if (def_arr == .array) {
                        for (def_arr.array.items) |item| {
                            if (item == .string) {
                                try self.format_icons.append(self.allocator, try allocator.dupe(u8, item.string));
                            }
                        }
                    }
                }
            } else if (icons_val == .array) {
                for (icons_val.array.items) |item| {
                    if (item == .string) {
                        try self.format_icons.append(self.allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }

        if (self.format_icons.items.len == 0) {
            try self.format_icons.append(self.allocator, try allocator.dupe(u8, ""));
            try self.format_icons.append(self.allocator, try allocator.dupe(u8, ""));
            try self.format_icons.append(self.allocator, try allocator.dupe(u8, ""));
        }

        self.base.custom_scroll_handler = &onScroll;
        self.base.custom_scroll_data = self;

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(1, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *WireplumberModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        for (self.format_icons.items) |ic| {
            self.allocator.free(ic);
        }
        self.format_icons.deinit(self.allocator);
        self.allocator.free(self.format);
        self.allocator.free(self.format_muted);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *WireplumberModule) void {
        var pw: sysinfo.pipewire = .init(self.io, self.allocator, undefined, undefined);
        const info = pw.getAudioInfo() catch {
            self.base.setText("Audio N/A");
            self.base.setTooltip("PipeWire audio service not responding");
            return;
        };
        var mutable_info = info;
        defer mutable_info.deinit(self.allocator);

        if (mutable_info.muted) {
            self.base.setText(self.format_muted);
            var tt_buf: [256]u8 = undefined;
            const tt = mem.print(&tt_buf, "{s}\nVolume: {d}% [MUTED]", .{
                mutable_info.node_name,
                mutable_info.volume,
            }) catch "Muted";
            self.base.setTooltip(tt);
            self.base.addCssClass("muted");
            return;
        }

        self.base.removeCssClass("muted");

        const icon_str = self.getIconForVolume(mutable_info.volume);

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", icon_str) catch {};
        replacer.addKeyAny("volume", @as(i64, mutable_info.volume)) catch {};
        replacer.addKey("node_name", mutable_info.node_name) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "{s}\nVolume: {d}%", .{
            mutable_info.node_name,
            mutable_info.volume,
        }) catch "Volume";
        self.base.setTooltip(tt);
    }

    fn getIconForVolume(self: *WireplumberModule, vol: u8) []const u8 {
        if (self.format_icons.items.len == 0) return "";
        if (self.format_icons.items.len == 1) return self.format_icons.items[0];

        const idx = (@as(usize, vol) * (self.format_icons.items.len - 1)) / 100;
        const safe_idx = @min(idx, self.format_icons.items.len - 1);
        return self.format_icons.items[safe_idx];
    }

    pub fn adjustVolume(self: *WireplumberModule, step_percent: f64) void {
        var buf: [128]u8 = undefined;
        const step_ratio = step_percent / 100.0;
        const printed = if (step_percent >= 0)
            mem.print(&buf, "wpctl set-volume -l {d:.2} @DEFAULT_AUDIO_SINK@ {d:.2}+\x00", .{
                @as(f64, @floatFromInt(self.max_volume)) / 100.0,
                step_ratio,
            }) catch return
        else
            mem.print(&buf, "wpctl set-volume @DEFAULT_AUDIO_SINK@ {d:.2}-\x00", .{
                @abs(step_ratio),
            }) catch return;

        _ = gtk.g_spawn_command_line_async(@ptrCast(printed.ptr), null);
        self.update();
    }
};

fn onScroll(user_data: ?*anyopaque, dy: f64) void {
    const self: *WireplumberModule = @ptrCast(@alignCast(user_data orelse return));
    if (dy < 0) {
        self.adjustVolume(self.scroll_step);
    } else if (dy > 0) {
        self.adjustVolume(-self.scroll_step);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *WireplumberModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
