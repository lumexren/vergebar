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
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

pub const MprisModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    format_stopped: []const u8,
    status_icon_paused: []const u8,
    status_icon_playing: []const u8,
    max_length: usize,
    min_length: usize,
    player: ?[]const u8,
    ignored_players: ArrayList([]const u8),
    timer_id: u32 = 0,
    conn: ?*gtk.GDBusConnection = null,
    sub_props: c_uint = 0,
    sub_names: c_uint = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*MprisModule {
        const self = try allocator.create(MprisModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click") orelse "playerctl play-pause";
        const on_click_middle = settings.getString("on-click-middle") orelse "playerctl previous";
        const on_click_right = settings.getString("on-click-right") orelse "playerctl next";

        self.base = try BaseModule.init(allocator, name, "mpris", on_click, on_click_middle, on_click_right);
        errdefer self.base.deinit();

        self.allocator = allocator;
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "{status_icon}  {title}");
        self.format_stopped = try allocator.dupe(u8, settings.getString("format-stopped") orelse "");

        var paused_icon: []const u8 = "";
        var playing_icon: []const u8 = "";
        if (settings.value == .object and settings.value.object.get("status-icons") != null) {
            const icons_val = settings.value.object.get("status-icons").?;
            if (icons_val == .object) {
                if (icons_val.object.get("paused")) |p| {
                    if (p == .string) paused_icon = p.string;
                }
                if (icons_val.object.get("playing")) |pl| {
                    if (pl == .string) playing_icon = pl.string;
                }
            }
        }
        self.status_icon_paused = try allocator.dupe(u8, paused_icon);
        self.status_icon_playing = try allocator.dupe(u8, playing_icon);

        self.max_length = @intCast(settings.getInt("max-length") orelse 40);
        self.min_length = @intCast(settings.getInt("min-length") orelse 0);
        self.player = if (settings.getString("player")) |p| try allocator.dupe(u8, p) else null;

        self.ignored_players = .empty;
        if (settings.value == .object and settings.value.object.get("ignored-players") != null) {
            const ig_val = settings.value.object.get("ignored-players").?;
            if (ig_val == .array) {
                for (ig_val.array.items) |item| {
                    if (item == .string) {
                        try self.ignored_players.append(self.allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }

        var err: ?*anyopaque = null;
        self.conn = gtk.g_bus_get_sync(2, null, &err);
        if (self.conn) |c| {
            self.sub_props = gtk.g_dbus_connection_signal_subscribe(
                c,
                null,
                "org.freedesktop.DBus.Properties",
                "PropertiesChanged",
                "/org/mpris/MediaPlayer2",
                "org.mpris.MediaPlayer2.Player",
                0,
                @ptrCast(&onMprisSignal),
                self,
                null,
            );
            self.sub_names = gtk.g_dbus_connection_signal_subscribe(
                c,
                "org.freedesktop.DBus",
                "org.freedesktop.DBus",
                "NameOwnerChanged",
                "/org/freedesktop/DBus",
                null,
                0,
                @ptrCast(&onNameOwnerChanged),
                self,
                null,
            );
        }

        self.update();

        self.timer_id = gtk.g_timeout_add_seconds(2, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *MprisModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        if (self.conn) |c| {
            if (self.sub_props != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sub_props);
            if (self.sub_names != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sub_names);
            gtk.g_object_unref(c);
            self.conn = null;
        }
        if (self.player) |p| self.allocator.free(p);
        for (self.ignored_players.items) |ig| self.allocator.free(ig);
        self.ignored_players.deinit(self.allocator);
        self.allocator.free(self.format);
        self.allocator.free(self.format_stopped);
        self.allocator.free(self.status_icon_paused);
        self.allocator.free(self.status_icon_playing);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *MprisModule) void {
        const c = self.conn orelse return;

        const player_name = self.findActivePlayer(c) orelse {
            self.renderStopped();
            return;
        };
        defer self.allocator.free(player_name);

        self.fetchAndRender(c, player_name);
    }

    fn renderStopped(self: *MprisModule) void {
        if (self.format_stopped.len > 0) {
            self.base.setText(self.format_stopped);
        } else {
            self.base.setText("");
        }
        self.base.setTooltip("No active media player");
        self.base.removeCssClass("playing");
        self.base.removeCssClass("paused");
    }

    fn findActivePlayer(self: *MprisModule, conn: *gtk.GDBusConnection) ?[]const u8 {
        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_connection_call_sync(
            conn,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            null,
            null,
            0,
            1000,
            null,
            &err,
        );
        if (res == null) {
            if (err) |e| gtk.g_error_free(e);
            return null;
        }
        defer gtk.g_variant_unref(res);

        const outer = gtk.g_variant_get_child_value(res, 0);
        if (outer == null) return null;
        defer gtk.g_variant_unref(outer);

        const iter = gtk.g_variant_iter_new(outer);
        if (iter == null) return null;
        defer gtk.g_variant_iter_free(iter);

        var best_playing: ?[]const u8 = null;
        var first_player: ?[]const u8 = null;

        while (gtk.g_variant_iter_next_value(iter)) |val| {
            defer gtk.g_variant_unref(val);
            const name_z = gtk.g_variant_get_string(val, null) orelse continue;
            const name = mem.span(name_z);

            if (!mem.startsWith(u8, name, "org.mpris.MediaPlayer2.")) continue;

            const short_name = name["org.mpris.MediaPlayer2.".len..];

            if (self.player) |target| {
                if (!mem.eql(u8, short_name, target) and !mem.startsWith(u8, short_name, target)) {
                    continue;
                }
            }

            var is_ignored = false;
            for (self.ignored_players.items) |ig| {
                if (mem.startsWith(u8, short_name, ig)) {
                    is_ignored = true;
                    break;
                }
            }
            if (is_ignored) continue;

            const status = self.getPlayerPlaybackStatus(conn, name_z);
            if (mem.eql(u8, status, "Playing")) {
                if (best_playing == null) {
                    best_playing = self.allocator.dupe(u8, name) catch null;
                    break;
                }
            } else if (first_player == null) {
                first_player = self.allocator.dupe(u8, name) catch null;
            }
        }

        if (best_playing) |bp| {
            if (first_player) |fp| self.allocator.free(fp);
            return bp;
        }

        return first_player;
    }

    fn getPlayerPlaybackStatus(self: *MprisModule, conn: *gtk.GDBusConnection, bus_name: [*:0]const u8) []const u8 {
        _ = self;
        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_connection_call_sync(
            conn,
            bus_name,
            "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties",
            "Get",
            gtk.g_variant_new_parsed("(%s, %s)", "org.mpris.MediaPlayer2.Player", "PlaybackStatus"),
            null,
            0,
            500,
            null,
            &err,
        );
        if (res == null) {
            if (err) |e| gtk.g_error_free(e);
            return "";
        }
        defer gtk.g_variant_unref(res);

        const outer = gtk.g_variant_get_child_value(res, 0);
        if (outer == null) return "";
        defer gtk.g_variant_unref(outer);

        const inner = gtk.g_variant_get_child_value(outer, 0);
        if (inner == null) return "";
        defer gtk.g_variant_unref(inner);

        const status_z = gtk.g_variant_get_string(inner, null) orelse return "";
        return mem.span(status_z);
    }

    fn fetchAndRender(self: *MprisModule, conn: *gtk.GDBusConnection, bus_name: []const u8) void {
        const bus_name_z = self.allocator.dupeSentinel(u8, bus_name, 0) catch return;
        defer self.allocator.free(bus_name_z);

        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_connection_call_sync(
            conn,
            bus_name_z.ptr,
            "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties",
            "GetAll",
            gtk.g_variant_new_parsed("(%s,)", "org.mpris.MediaPlayer2.Player"),
            null,
            0,
            1000,
            null,
            &err,
        );
        if (res == null) {
            if (err) |e| gtk.g_error_free(e);
            self.renderStopped();
            return;
        }
        defer gtk.g_variant_unref(res);

        const dict = gtk.g_variant_get_child_value(res, 0);
        if (dict == null) {
            self.renderStopped();
            return;
        }
        defer gtk.g_variant_unref(dict);

        var title: []const u8 = "";
        var artist: []const u8 = "";
        var album: []const u8 = "";
        var playback_status: []const u8 = "Paused";

        const iter = gtk.g_variant_iter_new(dict);
        if (iter) |it| {
            defer gtk.g_variant_iter_free(it);
            while (gtk.g_variant_iter_next_value(it)) |entry| {
                defer gtk.g_variant_unref(entry);
                const key_v = gtk.g_variant_get_child_value(entry, 0);
                const val_v = gtk.g_variant_get_child_value(entry, 1);
                defer if (key_v) |k| gtk.g_variant_unref(k);
                defer if (val_v) |v| gtk.g_variant_unref(v);

                if (key_v == null or val_v == null) continue;
                const key_z = gtk.g_variant_get_string(key_v, null) orelse continue;
                const key = mem.span(key_z);

                const inner_v = gtk.g_variant_get_child_value(val_v, 0);
                defer if (inner_v) |inv| gtk.g_variant_unref(inv);
                if (inner_v == null) continue;

                if (mem.eql(u8, key, "PlaybackStatus")) {
                    if (gtk.g_variant_get_string(inner_v, null)) |sz| {
                        playback_status = mem.span(sz);
                    }
                } else if (mem.eql(u8, key, "Metadata")) {
                    const meta_iter = gtk.g_variant_iter_new(inner_v);
                    if (meta_iter) |mit| {
                        defer gtk.g_variant_iter_free(mit);
                        while (gtk.g_variant_iter_next_value(mit)) |m_entry| {
                            defer gtk.g_variant_unref(m_entry);
                            const mk_v = gtk.g_variant_get_child_value(m_entry, 0);
                            const mv_v = gtk.g_variant_get_child_value(m_entry, 1);
                            defer if (mk_v) |mk| gtk.g_variant_unref(mk);
                            defer if (mv_v) |mv| gtk.g_variant_unref(mv);
                            if (mk_v == null or mv_v == null) continue;

                            const mk_z = gtk.g_variant_get_string(mk_v, null) orelse continue;
                            const mk = mem.span(mk_z);

                            const minner_v = gtk.g_variant_get_child_value(mv_v, 0);
                            defer if (minner_v) |minv| gtk.g_variant_unref(minv);
                            if (minner_v == null) continue;

                            if (mem.eql(u8, mk, "xesam:title")) {
                                if (gtk.g_variant_is_of_type(minner_v, "s") != 0) {
                                    if (gtk.g_variant_get_string(minner_v, null)) |sz| {
                                        title = mem.span(sz);
                                    }
                                }
                            } else if (mem.eql(u8, mk, "xesam:album")) {
                                if (gtk.g_variant_is_of_type(minner_v, "s") != 0) {
                                    if (gtk.g_variant_get_string(minner_v, null)) |sz| {
                                        album = mem.span(sz);
                                    }
                                }
                            } else if (mem.eql(u8, mk, "xesam:artist")) {
                                if (gtk.g_variant_is_of_type(minner_v, "as") != 0) {
                                    const as_iter = gtk.g_variant_iter_new(minner_v);
                                    if (as_iter) |ait| {
                                        defer gtk.g_variant_iter_free(ait);
                                        if (gtk.g_variant_iter_next_value(ait)) |first_art| {
                                            defer gtk.g_variant_unref(first_art);
                                            if (gtk.g_variant_is_of_type(first_art, "s") != 0) {
                                                if (gtk.g_variant_get_string(first_art, null)) |asz| {
                                                    artist = mem.span(asz);
                                                }
                                            }
                                        }
                                    }
                                } else if (gtk.g_variant_is_of_type(minner_v, "s") != 0) {
                                    if (gtk.g_variant_get_string(minner_v, null)) |sz| {
                                        artist = mem.span(sz);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        const is_playing = mem.eql(u8, playback_status, "Playing");
        const status_icon = if (is_playing) self.status_icon_playing else self.status_icon_paused;

        if (is_playing) {
            self.base.addCssClass("playing");
            self.base.removeCssClass("paused");
        } else {
            self.base.addCssClass("paused");
            self.base.removeCssClass("playing");
        }

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        const short_player = if (bus_name.len > "org.mpris.MediaPlayer2.".len)
            bus_name["org.mpris.MediaPlayer2.".len..]
        else
            bus_name;

        replacer.addKey("status_icon", status_icon) catch {};
        replacer.addKey("title", if (title.len > 0) title else "No Title") catch {};
        replacer.addKey("artist", artist) catch {};
        replacer.addKey("album", album) catch {};
        replacer.addKey("player", short_player) catch {};
        replacer.addKey("status", playback_status) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        const final_text = if (rendered.len > self.max_length and self.max_length > 3)
            fmt.allocPrint(self.allocator, "{s}...", .{rendered[0 .. self.max_length - 3]}) catch rendered
        else
            rendered;
        defer if (final_text.ptr != rendered.ptr and final_text.ptr != self.format.ptr) self.allocator.free(final_text);

        self.base.setText(final_text);

        var tt_buf: [512]u8 = undefined;
        const tt = mem.print(&tt_buf, "Player: {s}\nTitle: {s}\nArtist: {s}\nAlbum: {s}\nStatus: {s}", .{
            short_player,
            if (title.len > 0) title else "Unknown",
            if (artist.len > 0) artist else "Unknown",
            if (album.len > 0) album else "Unknown",
            playback_status,
        }) catch "MPRIS";
        self.base.setTooltip(tt);
    }
};

fn onMprisSignal(
    connection: ?*gtk.GDBusConnection,
    sender_name: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    signal_name: ?[*:0]const u8,
    parameters: ?*gtk.GVariant,
    user_data: gtk.gpointer,
) callconv(.c) void {
    _ = connection;
    _ = sender_name;
    _ = object_path;
    _ = interface_name;
    _ = signal_name;
    _ = parameters;
    const self: *MprisModule = @ptrCast(@alignCast(user_data orelse return));
    self.update();
}

fn onNameOwnerChanged(
    connection: ?*gtk.GDBusConnection,
    sender_name: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    signal_name: ?[*:0]const u8,
    parameters: ?*gtk.GVariant,
    user_data: gtk.gpointer,
) callconv(.c) void {
    _ = connection;
    _ = sender_name;
    _ = object_path;
    _ = interface_name;
    _ = signal_name;
    const self: *MprisModule = @ptrCast(@alignCast(user_data orelse return));
    if (parameters) |params| {
        const name_val = gtk.g_variant_get_child_value(params, 0);
        defer if (name_val) |nv| gtk.g_variant_unref(nv);
        if (name_val) |nv| {
            if (gtk.g_variant_get_string(nv, null)) |name_z| {
                if (mem.startsWith(u8, mem.span(name_z), "org.mpris.MediaPlayer2.")) {
                    self.update();
                }
            }
        }
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *MprisModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
