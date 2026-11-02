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
const Replacer = @import("utils").Replacer;
const Context = @import("utils").Context;

pub const JackModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    format_connected: []const u8,
    format_disconnected: []const u8,
    format_xrun: []const u8,
    tooltip_format: []const u8,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*JackModule {
        const self = try allocator.create(JackModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "jack", settings);
        errdefer base_mod.deinit();

        const fmt_str = settings.getString("format") orelse "{load}%";
        const fmt_conn = settings.getString("format-connected") orelse "{load}%";
        const fmt_disc = settings.getString("format-disconnected") orelse "disconnected";
        const fmt_xrun = settings.getString("format-xrun") orelse "xrun";
        const tt_fmt = settings.getString("tooltip-format") orelse "{bufsize}/{samplerate} {latency}ms";

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, fmt_str),
            .format_connected = try allocator.dupe(u8, fmt_conn),
            .format_disconnected = try allocator.dupe(u8, fmt_disc),
            .format_xrun = try allocator.dupe(u8, fmt_xrun),
            .tooltip_format = try allocator.dupe(u8, tt_fmt),
        };

        self.update();
        const interval_sec: u32 = if (settings.getInt("interval")) |iv| @intCast(@max(1, iv)) else 1;
        self.timer_id = gtk.g_timeout_add_seconds(interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *JackModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.allocator.free(self.format_connected);
        self.allocator.free(self.format_disconnected);
        self.allocator.free(self.format_xrun);
        self.allocator.free(self.tooltip_format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *JackModule) void {
        var buf: [512]u8 = undefined;
        const len = Context.runShellBuf("pw-metadata -n settings 2>/dev/null | grep -E 'clock.rate|clock.quantum'", &buf);

        if (len > 0) {
            var samplerate: u32 = 48000;
            var bufsize: u32 = 1024;
            const slice = buf[0..len];

            if (mem.indexOf(u8, slice, "clock.rate")) |idx| {
                const rest = slice[idx..];
                if (mem.indexOf(u8, rest, "value:'")) |val_idx| {
                    const num_start = val_idx + 7;
                    if (mem.indexOfScalar(u8, rest[num_start..], '\'')) |num_end| {
                        samplerate = fmt.parseInt(u32, rest[num_start .. num_start + num_end], 10) catch 48000;
                    }
                }
            }

            if (mem.indexOf(u8, slice, "clock.quantum")) |idx| {
                const rest = slice[idx..];
                if (mem.indexOf(u8, rest, "value:'")) |val_idx| {
                    const num_start = val_idx + 7;
                    if (mem.indexOfScalar(u8, rest[num_start..], '\'')) |num_end| {
                        bufsize = fmt.parseInt(u32, rest[num_start .. num_start + num_end], 10) catch 1024;
                    }
                }
            }

            const latency_ms: f64 = if (samplerate > 0) (@as(f64, @floatFromInt(bufsize)) * 1000.0) / @as(f64, @floatFromInt(samplerate)) else 0.0;

            self.base.removeCssClass("disconnected");
            self.base.addCssClass("connected");

            var replacer: Replacer = .init(self.allocator);
            defer replacer.deinit();

            replacer.addKeyAny("load", @as(i64, 0)) catch {};
            replacer.addKeyAny("bufsize", bufsize) catch {};
            replacer.addKeyAny("samplerate", samplerate) catch {};
            replacer.addKeyAny("latency", latency_ms) catch {};
            replacer.addKeyAny("xruns", @as(i64, 0)) catch {};

            const rendered = replacer.render(self.format_connected) catch self.format_connected;
            defer if (rendered.ptr != self.format_connected.ptr) self.allocator.free(rendered);
            self.base.setText(rendered);

            const tt = replacer.render(self.tooltip_format) catch self.tooltip_format;
            defer if (tt.ptr != self.tooltip_format.ptr) self.allocator.free(tt);
            self.base.setTooltip(tt);
        } else {
            self.base.removeCssClass("connected");
            self.base.addCssClass("disconnected");
            self.base.setText(self.format_disconnected);
            self.base.setTooltip("JACK (disconnected)");
        }
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *JackModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
