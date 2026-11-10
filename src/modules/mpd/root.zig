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

const MpdModule = @This();

pub const MpdData = @import("MpdData.zig");

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
const env = @import("utils").env;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
server: []const u8,
port: u16,
password: ?[]const u8,
format: []const u8,
format_stopped: []const u8,
format_paused: []const u8,
format_disconnected: []const u8,
tooltip_format: []const u8,
tooltip_format_disconnected: []const u8,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*MpdModule {
    const this = try allocator.create(MpdModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "mpd", settings);
    errdefer base_mod.deinit();

    const srv = settings.getString("server") orelse (env.get("MPD_HOST") orelse "localhost");
    const port_num: u16 = if (settings.getInt("port")) |p| @intCast(p) else 6600;
    const pass = settings.getString("password");

    const fmt_str = settings.getString("format") orelse "{artist} - {title}";
    const fmt_stopped = settings.getString("format-stopped") orelse "stopped";
    const fmt_paused = settings.getString("format-paused") orelse "{artist} - {title}";
    const fmt_disconnected = settings.getString("format-disconnected") orelse "disconnected";
    const tt_fmt = settings.getString("tooltip-format") orelse "{artist} - {title} [{elapsedTime}/{totalTime}]";
    const tt_disconnected = settings.getString("tooltip-format-disconnected") orelse "MPD (disconnected)";

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .server = try allocator.dupe(u8, srv),
        .port = port_num,
        .password = if (pass) |p| try allocator.dupe(u8, p) else null,
        .format = try allocator.dupe(u8, fmt_str),
        .format_stopped = try allocator.dupe(u8, fmt_stopped),
        .format_paused = try allocator.dupe(u8, fmt_paused),
        .format_disconnected = try allocator.dupe(u8, fmt_disconnected),
        .tooltip_format = try allocator.dupe(u8, tt_fmt),
        .tooltip_format_disconnected = try allocator.dupe(u8, tt_disconnected),
    };

    this.update();
    const interval_sec: u32 = if (settings.getInt("interval")) |iv| @intCast(@max(1, iv)) else 1;
    this.timer_id = gtk.g_timeout_add_seconds(interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *MpdModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.replacer.deinit();
    this.allocator.free(this.server);
    if (this.password) |p| this.allocator.free(p);
    this.allocator.free(this.format);
    this.allocator.free(this.format_stopped);
    this.allocator.free(this.format_paused);
    this.allocator.free(this.format_disconnected);
    this.allocator.free(this.tooltip_format);
    this.allocator.free(this.tooltip_format_disconnected);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *MpdModule) void {
    var response_buf: [2048]u8 = undefined;
    const res = queryMpd(this.base.io, this.server, this.port, this.password, &response_buf);

    if (res) |data| {
        const replacer = &this.replacer;
        replacer.clear();

        replacer.addKey("artist", data.artist) catch {};
        replacer.addKey("title", data.title) catch {};
        replacer.addKey("album", data.album) catch {};
        replacer.addKey("albumArtist", data.album_artist) catch {};
        replacer.addKey("state", data.state) catch {};
        replacer.addKey("elapsedTime", data.elapsed) catch {};
        replacer.addKey("totalTime", data.total) catch {};
        replacer.addKey("volume", data.volume) catch {};

        var active_format = this.format;
        if (mem.eql(u8, data.state, "stop")) {
            active_format = this.format_stopped;
            this.base.removeCssClass("playing");
            this.base.removeCssClass("paused");
            this.base.addCssClass("stopped");
        } else if (mem.eql(u8, data.state, "pause")) {
            active_format = this.format_paused;
            this.base.removeCssClass("playing");
            this.base.removeCssClass("stopped");
            this.base.addCssClass("paused");
        } else {
            this.base.removeCssClass("paused");
            this.base.removeCssClass("stopped");
            this.base.addCssClass("playing");
        }

        const rendered = replacer.render(active_format) catch active_format;
        defer if (rendered.ptr != active_format.ptr) this.allocator.free(rendered);
        this.base.setText(rendered);

        const tt = replacer.render(this.tooltip_format) catch this.tooltip_format;
        defer if (tt.ptr != this.tooltip_format.ptr) this.allocator.free(tt);
        this.base.setTooltip(tt);
    } else {
        this.base.removeCssClass("playing");
        this.base.removeCssClass("paused");
        this.base.removeCssClass("stopped");
        this.base.addCssClass("disconnected");
        this.base.setText(this.format_disconnected);
        this.base.setTooltip(this.tooltip_format_disconnected);
    }
}

fn queryMpd(io: Io, server: []const u8, port: u16, password: ?[]const u8, buf: []u8) ?MpdData {
    _ = password;
    _ = port;
    _ = server;

    const len = sh.runBuf(io, "mpc status 2>/dev/null", buf);
    if (len == 0) return null;

    const output = buf[0..len];
    if (mem.startsWith(u8, output, "MPD error:")) return null;

    var data: MpdData = .{};

    var line_it = mem.splitScalar(u8, output, '\n');
    const first_line = line_it.next() orelse return null;

    if (mem.find(u8, first_line, " - ")) |dash_idx| {
        data.artist = mem.trim(u8, first_line[0..dash_idx], " ");
        data.title = mem.trim(u8, first_line[dash_idx + 3 ..], " ");
    } else {
        data.title = mem.trim(u8, first_line, " \r\n");
    }

    if (line_it.next()) |second_line| {
        if (mem.startsWith(u8, second_line, "[playing]")) {
            data.state = "play";
        } else if (mem.startsWith(u8, second_line, "[paused]")) {
            data.state = "pause";
        } else {
            data.state = "stop";
        }
    }

    return data;
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *MpdModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
