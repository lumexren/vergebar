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
const utils = @import("utils");
const Replacer = utils.Replacer;
const Context = utils.Context;

pub const BacklightModule = struct {
    base: *BaseModule,
    format: []const u8,
    icon: []const u8,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*BacklightModule {
        const self = try allocator.create(BacklightModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "backlight", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{icon}  {percentage}%");
        self.icon = try allocator.dupe(u8, settings.getString("icon") orelse "");
        self.interval_sec = @intCast(settings.getInt("interval") orelse 2);

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *BacklightModule) void {
        if (self.timer_id != 0) _ = gtk.g_source_remove(self.timer_id);
        self.base.allocator.free(self.format);
        self.base.allocator.free(self.icon);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn update(self: *BacklightModule) void {
        var percentage: i64 = 100;

        const candidates = [_][]const u8{
            "/sys/class/backlight/intel_backlight",
            "/sys/class/backlight/amdgpu_bl0",
            "/sys/class/backlight/amdgpu_bl1",
            "/sys/class/backlight/acpi_video0",
            "/sys/class/backlight/nvidia_0",
        };

        for (candidates) |prefix| {
            var b_buf: [128]u8 = undefined;
            var m_buf: [128]u8 = undefined;
            const b_str = mem.print(&b_buf, "{s}/brightness", .{prefix}) catch continue;
            const m_str = mem.print(&m_buf, "{s}/max_brightness", .{prefix}) catch continue;

            var cb: [16]u8 = undefined;
            var mb: [16]u8 = undefined;
            const c_line = Context.readSysfsLine(b_str, &cb);
            const m_line = Context.readSysfsLine(m_str, &mb);

            if (c_line != null and m_line != null) {
                const cval = fmt.parseFloat(f64, c_line.?) catch 1.0;
                const mval = fmt.parseFloat(f64, m_line.?) catch 1.0;
                if (mval > 0) {
                    percentage = @intFromFloat(@round((cval / mval) * 100.0));
                    break;
                }
            }
        }

        var replacer: Replacer = .init(self.base.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", self.icon) catch {};
        replacer.addKeyAny("percentage", percentage) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.base.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [64]u8 = undefined;
        const tt = mem.print(&tt_buf, "Brightness: {d}%", .{percentage}) catch "Backlight";
        self.base.setTooltip(tt);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *BacklightModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
