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
const fmt = std.fmt;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const statvfs = @import("bindings").statvfs;

pub const DiskModule = struct {
    base: *BaseModule,
    path: []const u8,
    format: []const u8,
    icon: []const u8,
    warning_threshold: f64,
    critical_threshold: f64,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*DiskModule {
        const self = try allocator.create(DiskModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "disk", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.path = try allocator.dupe(u8, settings.getString("path") orelse "/");
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{icon}  {percentage_used}%");
        self.icon = try allocator.dupe(u8, settings.getString("icon") orelse "");
        self.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 80.0);
        self.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
        self.interval_sec = @intCast(settings.getInt("interval") orelse 10);

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *DiskModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
        }
        self.base.allocator.free(self.path);
        self.base.allocator.free(self.format);
        self.base.allocator.free(self.icon);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn update(self: *DiskModule) void {
        var stat: statvfs.Statfs = undefined;
        var path_z: [256]u8 = undefined;
        const len = @min(self.path.len, path_z.len - 1);
        @memcpy(path_z[0..len], self.path[0..len]);
        path_z[len] = 0;

        if (statvfs.statfs(path_z[0..len :0], &stat) != 0) return;

        const bsize: u64 = if (stat.f_frsize > 0) @intCast(stat.f_frsize) else @intCast(stat.f_bsize);
        const total_bytes = stat.f_blocks * bsize;
        const free_bytes = stat.f_bavail * bsize;
        const used_bytes = total_bytes -| free_bytes;

        const total_gb = @as(f64, @floatFromInt(total_bytes)) / 1024.0 / 1024.0 / 1024.0;
        const free_gb = @as(f64, @floatFromInt(free_bytes)) / 1024.0 / 1024.0 / 1024.0;
        const used_gb = @as(f64, @floatFromInt(used_bytes)) / 1024.0 / 1024.0 / 1024.0;

        const used_pct = if (total_bytes > 0)
            (@as(f64, @floatFromInt(used_bytes)) / @as(f64, @floatFromInt(total_bytes))) * 100.0
        else
            0.0;
        const used_pct_int: i64 = @intFromFloat(@round(used_pct));

        var replacer: Replacer = .init(self.base.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", self.icon) catch {};
        replacer.addKey("path", self.path) catch {};
        replacer.addKeyAny("percentage_used", used_pct_int) catch {};
        replacer.addKeyAny("percentage_free", 100 - used_pct_int) catch {};
        replacer.addKeyAny("free", free_gb) catch {};
        replacer.addKeyAny("used", used_gb) catch {};
        replacer.addKeyAny("total", total_gb) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.base.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "{s}: {d:.1} GiB used / {d:.1} GiB total ({d:.1} GiB free)", .{
            self.path,
            used_gb,
            total_gb,
            free_gb,
        }) catch "Disk";
        self.base.setTooltip(tt);

        const is_warning = used_pct >= self.warning_threshold and used_pct < self.critical_threshold;
        const is_critical = used_pct >= self.critical_threshold;
        self.base.setClasses(is_warning, is_critical);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *DiskModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
