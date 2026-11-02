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
const Io = std.Io;
const fmt = std.fmt;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

pub const CpuModule = struct {
    base: *BaseModule,
    cpu: sysinfo.CPU,
    format: []const u8,
    icon: []const u8,
    warning_threshold: f64,
    critical_threshold: f64,
    interval_sec: u32,
    timer_id: u32 = 0,

    pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*CpuModule {
        const self = try allocator.create(CpuModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(allocator, name, "cpu", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.cpu = sysinfo.CPU.init(io, allocator);
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{icon}  {usage}%");
        self.icon = try allocator.dupe(u8, settings.getString("icon") orelse "");
        self.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 70.0);
        self.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
        self.interval_sec = @intCast(settings.getInt("interval") orelse 1);

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *CpuModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
        }
        self.cpu.deinit();
        self.base.allocator.free(self.format);
        self.base.allocator.free(self.icon);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn update(self: *CpuModule) void {
        self.cpu.update() catch return;

        const usage_pct = self.cpu.avg;
        const usage_int: i64 = @intFromFloat(@round(usage_pct));

        var max_freq_ghz: f64 = 0.0;
        for (self.cpu.cores) |core| {
            const freq_ghz = core.frequency.current.value.raw / 1000.0 / 1000.0;
            if (freq_ghz > max_freq_ghz) max_freq_ghz = freq_ghz;
        }

        var replacer: Replacer = .init(self.base.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", self.icon) catch {};
        replacer.addKeyAny("usage", usage_int) catch {};
        replacer.addKeyAny("usage_percentage", usage_int) catch {};
        replacer.addKeyAny("max_frequency", max_freq_ghz) catch {};
        replacer.addKeyAny("load_one", self.cpu.load_avg.one) catch {};
        replacer.addKeyAny("load_five", self.cpu.load_avg.five) catch {};
        replacer.addKeyAny("load_fifteen", self.cpu.load_avg.fifteen) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.base.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [512]u8 = undefined;
        const tt = mem.print(&tt_buf, "CPU Usage: {d:.1}%\nLoad: {d:.2} {d:.2} {d:.2}\nCores: {d}", .{
            usage_pct,
            self.cpu.load_avg.one,
            self.cpu.load_avg.five,
            self.cpu.load_avg.fifteen,
            self.cpu.cores.len,
        }) catch "CPU";
        self.base.setTooltip(tt);

        const is_warning = usage_pct >= self.warning_threshold and usage_pct < self.critical_threshold;
        const is_critical = usage_pct >= self.critical_threshold;
        self.base.setClasses(is_warning, is_critical);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *CpuModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
