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

const MprisModule = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
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
current_player: ?[:0]const u8 = null,
has_custom_click: bool = false,
has_custom_click_middle: bool = false,
has_custom_click_right: bool = false,
popover: ?*gtk.GtkWidget = null,
last_title: ?[]u8 = null,
last_artist: ?[]u8 = null,
last_album: ?[]u8 = null,
last_art_url: ?[]u8 = null,
last_status: ?[]u8 = null,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*MprisModule {
    const this = try allocator.create(MprisModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "mpris", settings);
    errdefer this.base.deinit();

    this.has_custom_click = this.base.on_click != null;
    this.has_custom_click_middle = this.base.on_click_middle != null;
    this.has_custom_click_right = this.base.on_click_right != null;

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.allocator = allocator;
    this.current_player = null;
    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    this.format = try allocator.dupe(u8, settings.getString("format") orelse "{status_icon}  {title}");
    this.format_stopped = try allocator.dupe(u8, settings.getString("format-stopped") orelse "");

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
    this.status_icon_paused = try allocator.dupe(u8, paused_icon);
    this.status_icon_playing = try allocator.dupe(u8, playing_icon);

    this.max_length = @intCast(settings.getInt("max-length") orelse 40);
    this.min_length = @intCast(settings.getInt("min-length") orelse 0);
    this.player = if (settings.getString("player")) |p| try allocator.dupe(u8, p) else null;

    this.ignored_players = .empty;
    if (settings.value == .object and settings.value.object.get("ignored-players") != null) {
        const ig_val = settings.value.object.get("ignored-players").?;
        if (ig_val == .array) {
            for (ig_val.array.items) |item| {
                if (item == .string) {
                    try this.ignored_players.append(this.allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }

    var err: ?*anyopaque = null;
    this.conn = gtk.g_bus_get_sync(2, null, &err);
    if (this.conn) |c| {
        this.sub_props = gtk.g_dbus_connection_signal_subscribe(
            c,
            null,
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
            0,
            @ptrCast(&onMprisSignal),
            this,
            null,
        );
        this.sub_names = gtk.g_dbus_connection_signal_subscribe(
            c,
            "org.freedesktop.DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            "/org/freedesktop/DBus",
            null,
            0,
            @ptrCast(&onNameOwnerChanged),
            this,
            null,
        );
    }

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(2, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *MprisModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    if (this.last_title) |t| this.allocator.free(t);
    if (this.last_artist) |a| this.allocator.free(a);
    if (this.last_album) |al| this.allocator.free(al);
    if (this.last_art_url) |u| this.allocator.free(u);
    if (this.last_status) |s| this.allocator.free(s);

    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.replacer.deinit();
    if (this.conn) |c| {
        if (this.sub_props != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sub_props);
        if (this.sub_names != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sub_names);
        gtk.g_object_unref(c);
        this.conn = null;
    }
    if (this.player) |p| this.allocator.free(p);
    for (this.ignored_players.items) |ig| this.allocator.free(ig);
    this.ignored_players.deinit(this.allocator);
    if (this.current_player) |cp| this.allocator.free(cp);
    this.allocator.free(this.format);
    this.allocator.free(this.format_stopped);
    this.allocator.free(this.status_icon_paused);
    this.allocator.free(this.status_icon_playing);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *MprisModule) void {
    const c = this.conn orelse return;

    const player_name = this.findActivePlayer(c) orelse {
        this.renderStopped();
        return;
    };
    defer this.allocator.free(player_name);

    this.fetchAndRender(c, player_name);
}

fn renderStopped(this: *MprisModule) void {
    if (this.current_player) |cp| {
        this.allocator.free(cp);
        this.current_player = null;
    }
    if (this.format_stopped.len > 0) {
        this.base.setText(this.format_stopped);
    } else {
        this.base.setText("");
    }
    this.base.setTooltip("No active media player");
    this.base.removeCssClass("playing");
    this.base.removeCssClass("paused");
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    const this: *MprisModule = @ptrCast(@alignCast(user_data orelse return false));
    const conn = this.conn orelse return false;
    const player_name = this.current_player orelse return false;

    if (btn_num == 1 and this.has_custom_click) return false;
    if (btn_num == 2 and this.has_custom_click_middle) return false;
    if (btn_num == 3 and this.has_custom_click_right) return false;

    if (btn_num == 3) {
        this.togglePlayerPopover();
        return true;
    }

    const method_name: [:0]const u8 = switch (btn_num) {
        1 => "PlayPause",
        2 => "Previous",
        else => return false,
    };

    _ = gtk.g_dbus_connection_call(
        conn,
        player_name.ptr,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        method_name.ptr,
        null,
        null,
        0,
        -1,
        null,
        null,
        null,
    );
    return true;
}

pub fn sendPlayerCommand(this: *MprisModule, method_name: [:0]const u8) void {
    const conn = this.conn orelse return;
    const player_name = this.current_player orelse return;

    _ = gtk.g_dbus_connection_call(
        conn,
        player_name.ptr,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        method_name.ptr,
        null,
        null,
        0,
        -1,
        null,
        null,
        null,
    );
    this.update();
}

pub fn togglePlayerPopover(this: *MprisModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const main_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8);
    if (main_box) |mb| {
        gtk.gtk_widget_add_css_class(mb, "mpris-popover");

        var art_loaded = false;
        if (this.last_art_url) |url| {
            if (mem.startsWith(u8, url, "file://")) {
                const local_path = url["file://".len..];
                var path_z_buf: [256]u8 = undefined;
                if (mem.printSentinel(&path_z_buf, "{s}", .{local_path}, 0)) |path_z| {
                    const img = gtk.gtk_image_new_from_file(@ptrCast(path_z.ptr));
                    if (img) |im| {
                        gtk.gtk_image_set_pixel_size(@ptrCast(im), 96);
                        gtk.gtk_box_append(@ptrCast(mb), im);
                        art_loaded = true;
                    }
                } else |_| {}
            }
        }
        if (!art_loaded) {
            const fallback_img = gtk.gtk_image_new_from_icon_name("audio-x-generic");
            if (fallback_img) |im| {
                gtk.gtk_image_set_pixel_size(@ptrCast(im), 64);
                gtk.gtk_box_append(@ptrCast(mb), im);
            }
        }

        const info_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
        if (info_box) |ib| {
            const title_str = this.last_title orelse "No Track";
            var title_buf: [128]u8 = undefined;
            const t_z = mem.printSentinel(&title_buf, "{s}", .{title_str}, 0) catch "No Track";
            const title_lbl = gtk.gtk_label_new(@ptrCast(t_z.ptr));
            if (title_lbl) |tl| {
                gtk.gtk_widget_add_css_class(tl, "title");
                gtk.gtk_box_append(@ptrCast(ib), tl);
            }

            var sub_buf: [256]u8 = undefined;
            const artist_str = this.last_artist orelse "";
            const album_str = this.last_album orelse "";
            const sub_z = if (artist_str.len > 0 and album_str.len > 0)
                mem.printSentinel(&sub_buf, "{s} — {s}", .{ artist_str, album_str }, 0) catch artist_str
            else if (artist_str.len > 0)
                mem.printSentinel(&sub_buf, "{s}", .{artist_str}, 0) catch artist_str
            else
                "";
            if (sub_z.len > 0) {
                const sub_lbl = gtk.gtk_label_new(@ptrCast(sub_z.ptr));
                if (sub_lbl) |sl| {
                    gtk.gtk_widget_add_css_class(sl, "subtitle");
                    gtk.gtk_box_append(@ptrCast(ib), sl);
                }
            }
            gtk.gtk_box_append(@ptrCast(mb), ib);
        }

        const pbar = gtk.gtk_progress_bar_new();
        if (pbar) |pb| {
            gtk.gtk_widget_add_css_class(pb, "mpris-progress");
            gtk.gtk_box_append(@ptrCast(mb), pb);
        }

        const ctrl_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
        if (ctrl_box) |cb| {
            const btn_prev = gtk.gtk_button_new_with_label("⏮");
            if (btn_prev) |bp| {
                _ = gtk.g_signal_connect_data(bp, "clicked", @ptrCast(&onPopPrevClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(cb), bp);
            }

            const is_playing = if (this.last_status) |st| mem.eql(u8, st, "Playing") else false;
            const pp_label: [:0]const u8 = if (is_playing) "⏸" else "▶";
            const btn_play = gtk.gtk_button_new_with_label(pp_label.ptr);
            if (btn_play) |bplay| {
                _ = gtk.g_signal_connect_data(bplay, "clicked", @ptrCast(&onPopPlayClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(cb), bplay);
            }

            const btn_next = gtk.gtk_button_new_with_label("⏭");
            if (btn_next) |bn| {
                _ = gtk.g_signal_connect_data(bn, "clicked", @ptrCast(&onPopNextClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(cb), bn);
            }

            gtk.gtk_box_append(@ptrCast(mb), cb);
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), mb);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onPopPrevClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *MprisModule = @ptrCast(@alignCast(user_data orelse return));
    this.sendPlayerCommand("Previous");
}

fn onPopPlayClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *MprisModule = @ptrCast(@alignCast(user_data orelse return));
    this.sendPlayerCommand("PlayPause");
}

fn onPopNextClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *MprisModule = @ptrCast(@alignCast(user_data orelse return));
    this.sendPlayerCommand("Next");
}

fn findActivePlayer(this: *MprisModule, conn: *gtk.GDBusConnection) ?[]const u8 {
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

        if (this.player) |target| {
            if (!mem.eql(u8, short_name, target) and !mem.startsWith(u8, short_name, target)) {
                continue;
            }
        }

        var is_ignored = false;
        for (this.ignored_players.items) |ig| {
            if (mem.startsWith(u8, short_name, ig)) {
                is_ignored = true;
                break;
            }
        }
        if (is_ignored) continue;

        const status = this.getPlayerPlaybackStatus(conn, name_z);
        if (mem.eql(u8, status, "Playing")) {
            if (best_playing == null) {
                best_playing = this.allocator.dupe(u8, name) catch null;
                break;
            }
        } else if (first_player == null) {
            first_player = this.allocator.dupe(u8, name) catch null;
        }
    }

    if (best_playing) |bp| {
        if (first_player) |fp| this.allocator.free(fp);
        return bp;
    }

    return first_player;
}

fn getPlayerPlaybackStatus(this: *MprisModule, conn: *gtk.GDBusConnection, bus_name: [*:0]const u8) []const u8 {
    _ = this;
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

fn fetchAndRender(this: *MprisModule, conn: *gtk.GDBusConnection, bus_name: []const u8) void {
    const bus_name_z = this.allocator.dupeSentinel(u8, bus_name, 0) catch return;
    defer this.allocator.free(bus_name_z);

    if (this.current_player) |cp| this.allocator.free(cp);
    this.current_player = this.allocator.dupeSentinel(u8, bus_name, 0) catch null;

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
        this.renderStopped();
        return;
    }
    defer gtk.g_variant_unref(res);

    const dict = gtk.g_variant_get_child_value(res, 0);
    if (dict == null) {
        this.renderStopped();
        return;
    }
    defer gtk.g_variant_unref(dict);

    var title: []const u8 = "";
    var artist: []const u8 = "";
    var album: []const u8 = "";
    var art_url: []const u8 = "";
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
                        } else if (mem.eql(u8, mk, "mpris:artUrl")) {
                            if (gtk.g_variant_is_of_type(minner_v, "s") != 0) {
                                if (gtk.g_variant_get_string(minner_v, null)) |sz| {
                                    art_url = mem.span(sz);
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
    const status_icon = if (is_playing) this.status_icon_playing else this.status_icon_paused;

    if (this.last_title) |lt| this.allocator.free(lt);
    this.last_title = this.allocator.dupe(u8, title) catch null;
    if (this.last_artist) |la| this.allocator.free(la);
    this.last_artist = this.allocator.dupe(u8, artist) catch null;
    if (this.last_album) |lal| this.allocator.free(lal);
    this.last_album = this.allocator.dupe(u8, album) catch null;
    if (this.last_art_url) |lau| this.allocator.free(lau);
    this.last_art_url = this.allocator.dupe(u8, art_url) catch null;
    if (this.last_status) |ls| this.allocator.free(ls);
    this.last_status = this.allocator.dupe(u8, playback_status) catch null;

    if (is_playing) {
        this.base.addCssClass("playing");
        this.base.removeCssClass("paused");
    } else {
        this.base.addCssClass("paused");
        this.base.removeCssClass("playing");
    }

    this.replacer.clear();

    const short_player = if (bus_name.len > "org.mpris.MediaPlayer2.".len)
        bus_name["org.mpris.MediaPlayer2.".len..]
    else
        bus_name;

    this.replacer.addKey("status_icon", status_icon) catch {};
    this.replacer.addKey("title", if (title.len > 0) title else "No Title") catch {};
    this.replacer.addKey("artist", artist) catch {};
    this.replacer.addKey("album", album) catch {};
    this.replacer.addKey("player", short_player) catch {};
    this.replacer.addKey("status", playback_status) catch {};

    const rendered = this.replacer.render(this.format) catch this.format;
    defer if (rendered.ptr != this.format.ptr) this.allocator.free(rendered);

    const final_text = if (rendered.len > this.max_length and this.max_length > 3)
        this.allocator.print("{s}...", .{rendered[0 .. this.max_length - 3]}) catch rendered
    else
        rendered;
    defer if (final_text.ptr != rendered.ptr and final_text.ptr != this.format.ptr) this.allocator.free(final_text);

    this.base.setText(final_text);

    var tt_buf: [512]u8 = undefined;
    const tt = mem.print(&tt_buf, "Player: {s}\nTitle: {s}\nArtist: {s}\nAlbum: {s}\nStatus: {s}", .{
        short_player,
        if (title.len > 0) title else "Unknown",
        if (artist.len > 0) artist else "Unknown",
        if (album.len > 0) album else "Unknown",
        playback_status,
    }) catch "MPRIS";
    this.base.setTooltip(tt);
}

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
    const this: *MprisModule = @ptrCast(@alignCast(user_data orelse return));
    this.update();
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
    const this: *MprisModule = @ptrCast(@alignCast(user_data orelse return));
    if (parameters) |params| {
        const name_val = gtk.g_variant_get_child_value(params, 0);
        defer if (name_val) |nv| gtk.g_variant_unref(nv);
        if (name_val) |nv| {
            if (gtk.g_variant_get_string(nv, null)) |name_z| {
                if (mem.startsWith(u8, mem.span(name_z), "org.mpris.MediaPlayer2.")) {
                    this.update();
                }
            }
        }
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *MprisModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
