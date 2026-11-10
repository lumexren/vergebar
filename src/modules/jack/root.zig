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

const JackModule = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const sh = @import("utils").sh;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
format: []const u8,
format_connected: []const u8,
format_disconnected: []const u8,
format_xrun: []const u8,
tooltip_format: []const u8,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*JackModule {
    const this = try allocator.create(JackModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "jack", settings);
    errdefer base_mod.deinit();

    const fmt_str = settings.getString("format") orelse "{load}%";
    const fmt_conn = settings.getString("format-connected") orelse "{load}%";
    const fmt_disc = settings.getString("format-disconnected") orelse "disconnected";
    const fmt_xrun = settings.getString("format-xrun") orelse "xrun";
    const tt_fmt = settings.getString("tooltip-format") orelse "{bufsize}/{samplerate} {latency}ms";

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .format = try allocator.dupe(u8, fmt_str),
        .format_connected = try allocator.dupe(u8, fmt_conn),
        .format_disconnected = try allocator.dupe(u8, fmt_disc),
        .format_xrun = try allocator.dupe(u8, fmt_xrun),
        .tooltip_format = try allocator.dupe(u8, tt_fmt),
    };

    this.update();
    const interval_sec: u32 = if (settings.getInt("interval")) |iv| @intCast(@max(1, iv)) else 1;
    this.timer_id = gtk.g_timeout_add_seconds(interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *JackModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.allocator.free(this.format_connected);
    this.allocator.free(this.format_disconnected);
    this.allocator.free(this.format_xrun);
    this.allocator.free(this.tooltip_format);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *JackModule) void {
    var buf: [512]u8 = undefined;
    const len = sh.runBuf(this.base.io, "pw-metadata -n settings 2>/dev/null | grep -E 'clock.rate|clock.quantum'", &buf);

    if (len > 0) {
        var samplerate: u32 = 48000;
        var bufsize: u32 = 1024;
        const slice = buf[0..len];

        if (mem.find(u8, slice, "clock.rate")) |idx| {
            const rest = slice[idx..];
            if (mem.find(u8, rest, "value:'")) |val_idx| {
                const num_start = val_idx + 7;
                if (mem.findScalar(u8, rest[num_start..], '\'')) |num_end| {
                    samplerate = fmt.parseInt(u32, rest[num_start .. num_start + num_end], 10) catch 48000;
                }
            }
        }

        if (mem.find(u8, slice, "clock.quantum")) |idx| {
            const rest = slice[idx..];
            if (mem.find(u8, rest, "value:'")) |val_idx| {
                const num_start = val_idx + 7;
                if (mem.findScalar(u8, rest[num_start..], '\'')) |num_end| {
                    bufsize = fmt.parseInt(u32, rest[num_start .. num_start + num_end], 10) catch 1024;
                }
            }
        }

        const latency_ms: f64 = if (samplerate > 0) (@as(f64, @floatFromInt(bufsize)) * 1000.0) / @as(f64, @floatFromInt(samplerate)) else 0.0;

        this.base.removeCssClass("disconnected");
        this.base.addCssClass("connected");

        const replacer = &this.replacer;
        replacer.clear();

        replacer.addKeyAny("load", @as(i64, 0)) catch {};
        replacer.addKeyAny("bufsize", bufsize) catch {};
        replacer.addKeyAny("samplerate", samplerate) catch {};
        replacer.addKeyAny("latency", latency_ms) catch {};
        replacer.addKeyAny("xruns", @as(i64, 0)) catch {};

        const rendered = replacer.render(this.format_connected) catch this.format_connected;
        defer if (rendered.ptr != this.format_connected.ptr) this.allocator.free(rendered);
        this.base.setText(rendered);

        const tt = replacer.render(this.tooltip_format) catch this.tooltip_format;
        defer if (tt.ptr != this.tooltip_format.ptr) this.allocator.free(tt);
        this.base.setTooltip(tt);
    } else {
        this.base.removeCssClass("connected");
        this.base.addCssClass("disconnected");
        this.base.setText(this.format_disconnected);
        this.base.setTooltip("JACK (disconnected)");
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *JackModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
