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

pub const MpdModule = struct {
    base: *BaseModule,
    allocator: Allocator,
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

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*MpdModule {
        const self = try allocator.create(MpdModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "mpd", settings);
        errdefer base_mod.deinit();

        const srv = settings.getString("server") orelse (Context.getEnv("MPD_HOST") orelse "localhost");
        const port_num: u16 = if (settings.getInt("port")) |p| @intCast(p) else 6600;
        const pass = settings.getString("password");

        const fmt_str = settings.getString("format") orelse "{artist} - {title}";
        const fmt_stopped = settings.getString("format-stopped") orelse "stopped";
        const fmt_paused = settings.getString("format-paused") orelse "{artist} - {title}";
        const fmt_disconnected = settings.getString("format-disconnected") orelse "disconnected";
        const tt_fmt = settings.getString("tooltip-format") orelse "{artist} - {title} [{elapsedTime}/{totalTime}]";
        const tt_disconnected = settings.getString("tooltip-format-disconnected") orelse "MPD (disconnected)";

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
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

        self.update();
        const interval_sec: u32 = if (settings.getInt("interval")) |iv| @intCast(@max(1, iv)) else 1;
        self.timer_id = gtk.g_timeout_add_seconds(interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *MpdModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.server);
        if (self.password) |p| self.allocator.free(p);
        self.allocator.free(self.format);
        self.allocator.free(self.format_stopped);
        self.allocator.free(self.format_paused);
        self.allocator.free(self.format_disconnected);
        self.allocator.free(self.tooltip_format);
        self.allocator.free(self.tooltip_format_disconnected);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *MpdModule) void {
        var response_buf: [2048]u8 = undefined;
        const res = queryMpd(self.server, self.port, self.password, &response_buf);

        if (res) |data| {
            var replacer: Replacer = .init(self.allocator);
            defer replacer.deinit();

            replacer.addKey("artist", data.artist) catch {};
            replacer.addKey("title", data.title) catch {};
            replacer.addKey("album", data.album) catch {};
            replacer.addKey("albumArtist", data.album_artist) catch {};
            replacer.addKey("state", data.state) catch {};
            replacer.addKey("elapsedTime", data.elapsed) catch {};
            replacer.addKey("totalTime", data.total) catch {};
            replacer.addKey("volume", data.volume) catch {};

            var active_format = self.format;
            if (mem.eql(u8, data.state, "stop")) {
                active_format = self.format_stopped;
                self.base.removeCssClass("playing");
                self.base.removeCssClass("paused");
                self.base.addCssClass("stopped");
            } else if (mem.eql(u8, data.state, "pause")) {
                active_format = self.format_paused;
                self.base.removeCssClass("playing");
                self.base.removeCssClass("stopped");
                self.base.addCssClass("paused");
            } else {
                self.base.removeCssClass("paused");
                self.base.removeCssClass("stopped");
                self.base.addCssClass("playing");
            }

            const rendered = replacer.render(active_format) catch active_format;
            defer if (rendered.ptr != active_format.ptr) self.allocator.free(rendered);
            self.base.setText(rendered);

            const tt = replacer.render(self.tooltip_format) catch self.tooltip_format;
            defer if (tt.ptr != self.tooltip_format.ptr) self.allocator.free(tt);
            self.base.setTooltip(tt);
        } else {
            self.base.removeCssClass("playing");
            self.base.removeCssClass("paused");
            self.base.removeCssClass("stopped");
            self.base.addCssClass("disconnected");
            self.base.setText(self.format_disconnected);
            self.base.setTooltip(self.tooltip_format_disconnected);
        }
    }
};

const MpdData = struct {
    state: []const u8 = "stop",
    artist: []const u8 = "Unknown",
    title: []const u8 = "Unknown",
    album: []const u8 = "",
    album_artist: []const u8 = "",
    elapsed: []const u8 = "0:00",
    total: []const u8 = "0:00",
    volume: []const u8 = "100",
};

fn queryMpd(server: []const u8, port: u16, password: ?[]const u8, buf: []u8) ?MpdData {
    _ = password;
    _ = port;
    _ = server;

    const len = Context.runShellBuf("mpc status 2>/dev/null", buf);
    if (len == 0) return null;

    const output = buf[0..len];
    if (mem.startsWith(u8, output, "MPD error:")) return null;

    var data: MpdData = .{};

    var line_it = mem.splitScalar(u8, output, '\n');
    const first_line = line_it.next() orelse return null;

    if (mem.indexOf(u8, first_line, " - ")) |dash_idx| {
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
    const self: *MpdModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
