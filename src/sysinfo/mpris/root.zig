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

pub const MprisError = @import("MprisError.zig").MprisError;
pub const PlaybackStatus = @import("PlaybackStatus.zig").PlaybackStatus;
pub const LoopStatus = @import("LoopStatus.zig").LoopStatus;
pub const Metadata = @import("Metadata.zig");
pub const PlayerInfo = @import("PlayerInfo.zig");

const gdbus = @import("bindings").gdbus;

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

pub const MPRIS_PREFIX = "org.mpris.MediaPlayer2.";
pub const MPRIS_PATH: [:0]const u8 = "/org/mpris/MediaPlayer2";
pub const PLAYER_IFACE: [:0]const u8 = "org.mpris.MediaPlayer2.Player";
pub const ROOT_IFACE: [:0]const u8 = "org.mpris.MediaPlayer2";

pub fn listPlayers(allocator: Allocator, connection: ?*gdbus.GDBusConnection) ![][]const u8 {
    var owns = false;
    var conn = connection;
    if (conn == null) {
        conn = gdbus.getBus(.session);
        owns = (conn != null);
    }
    const c = conn orelse return MprisError.ConnectionFailed;
    defer if (owns) gdbus.g_object_unref(c);

    const res = gdbus.callMethodSync(
        c,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "ListNames",
        null,
    ) orelse return MprisError.ConnectionFailed;
    defer gdbus.g_variant_unref(res);

    const outer = gdbus.g_variant_get_child_value(res, 0) orelse return MprisError.InvalidResponse;
    defer gdbus.g_variant_unref(outer);

    const iter = gdbus.g_variant_iter_new(outer) orelse return MprisError.InvalidResponse;
    defer gdbus.g_variant_iter_free(iter);

    var players: ArrayList([]const u8) = .empty;
    errdefer {
        for (players.items) |p| allocator.free(p);
        players.deinit(allocator);
    }

    while (gdbus.g_variant_iter_next_value(iter)) |name_val| {
        defer gdbus.g_variant_unref(name_val);
        const name = gdbus.asString(name_val) orelse continue;
        if (mem.startsWith(u8, name, MPRIS_PREFIX)) {
            try players.append(allocator, try allocator.dupe(u8, name));
        }
    }

    return players.toOwnedSlice(allocator);
}

pub fn getPlayerInfo(allocator: Allocator, connection: ?*gdbus.GDBusConnection, bus_name: []const u8) !PlayerInfo {
    var owns = false;
    var conn = connection;
    if (conn == null) {
        conn = gdbus.getBus(.session);
        owns = (conn != null);
    }
    const c = conn orelse return MprisError.ConnectionFailed;
    defer if (owns) gdbus.g_object_unref(c);

    const player_name = if (bus_name.len > MPRIS_PREFIX.len)
        bus_name[MPRIS_PREFIX.len..]
    else
        bus_name;

    var info: PlayerInfo = .{
        .name = try allocator.dupe(u8, player_name),
    };
    errdefer info.deinit(allocator);

    var bus_name_buf: [256]u8 = undefined;
    const bus_name_z = mem.printSentinel(&bus_name_buf, "{s}", .{bus_name}, 0) catch return MprisError.InvalidResponse;

    // Get Player interface properties
    {
        const p = gdbus.g_variant_new_string(PLAYER_IFACE);
        const params = gdbus.g_variant_new_tuple(&[_]*gdbus.GVariant{p}, 1);
        if (gdbus.callMethodSync(c, bus_name_z, MPRIS_PATH, "org.freedesktop.DBus.Properties", "GetAll", params)) |res| {
            defer gdbus.g_variant_unref(res);
            if (gdbus.g_variant_get_child_value(res, 0)) |outer| {
                defer gdbus.g_variant_unref(outer);
                if (gdbus.g_variant_iter_new(outer)) |iter| {
                    defer gdbus.g_variant_iter_free(iter);
                    while (gdbus.g_variant_iter_next_value(iter)) |entry| {
                        defer gdbus.g_variant_unref(entry);
                        const k_v = gdbus.g_variant_get_child_value(entry, 0);
                        const v_v = gdbus.g_variant_get_child_value(entry, 1);
                        defer if (k_v) |kv| gdbus.g_variant_unref(kv);
                        defer if (v_v) |vv| gdbus.g_variant_unref(vv);
                        if (k_v == null or v_v == null) continue;

                        const key = gdbus.asString(k_v.?) orelse continue;
                        const inner = gdbus.g_variant_get_variant(v_v.?);
                        defer gdbus.g_variant_unref(inner);

                        if (mem.eql(u8, key, "PlaybackStatus")) {
                            if (gdbus.asString(inner)) |s| {
                                if (mem.eql(u8, s, "Playing")) {
                                    info.status = .playing;
                                } else if (mem.eql(u8, s, "Paused")) {
                                    info.status = .paused;
                                } else if (mem.eql(u8, s, "Stopped")) {
                                    info.status = .stopped;
                                }
                            }
                        } else if (mem.eql(u8, key, "LoopStatus")) {
                            if (gdbus.asString(inner)) |s| {
                                if (mem.eql(u8, s, "None")) {
                                    info.loop_status = .none;
                                } else if (mem.eql(u8, s, "Track")) {
                                    info.loop_status = .track;
                                } else if (mem.eql(u8, s, "Playlist")) {
                                    info.loop_status = .playlist;
                                }
                            }
                        } else if (mem.eql(u8, key, "Shuffle")) {
                            if (gdbus.asBoolean(inner)) |b| info.shuffle = b;
                        } else if (mem.eql(u8, key, "CanControl")) {
                            if (gdbus.asBoolean(inner)) |b| info.can_control = b;
                        } else if (mem.eql(u8, key, "CanGoNext")) {
                            if (gdbus.asBoolean(inner)) |b| info.can_go_next = b;
                        } else if (mem.eql(u8, key, "CanGoPrevious")) {
                            if (gdbus.asBoolean(inner)) |b| info.can_go_previous = b;
                        } else if (mem.eql(u8, key, "CanPlay")) {
                            if (gdbus.asBoolean(inner)) |b| info.can_play = b;
                        } else if (mem.eql(u8, key, "CanPause")) {
                            if (gdbus.asBoolean(inner)) |b| info.can_pause = b;
                        } else if (mem.eql(u8, key, "CanSeek")) {
                            if (gdbus.asBoolean(inner)) |b| info.can_seek = b;
                        } else if (mem.eql(u8, key, "Volume")) {
                            if (gdbus.asDouble(inner)) |d| info.volume = d;
                        } else if (mem.eql(u8, key, "Position")) {
                            if (gdbus.asInt64(inner)) |pos| info.position_us = pos;
                        } else if (mem.eql(u8, key, "Metadata")) {
                            info.metadata = parseMetadata(allocator, inner);
                        }
                    }
                }
            }
        }
    }

    // Get Root interface properties
    {
        const p = gdbus.g_variant_new_string(ROOT_IFACE);
        const params = gdbus.g_variant_new_tuple(&[_]*gdbus.GVariant{p}, 1);
        if (gdbus.callMethodSync(c, bus_name_z, MPRIS_PATH, "org.freedesktop.DBus.Properties", "GetAll", params)) |res| {
            defer gdbus.g_variant_unref(res);
            if (gdbus.g_variant_get_child_value(res, 0)) |outer| {
                defer gdbus.g_variant_unref(outer);
                if (gdbus.g_variant_iter_new(outer)) |iter| {
                    defer gdbus.g_variant_iter_free(iter);
                    while (gdbus.g_variant_iter_next_value(iter)) |entry| {
                        defer gdbus.g_variant_unref(entry);
                        const k_v = gdbus.g_variant_get_child_value(entry, 0);
                        const v_v = gdbus.g_variant_get_child_value(entry, 1);
                        defer if (k_v) |kv| gdbus.g_variant_unref(kv);
                        defer if (v_v) |vv| gdbus.g_variant_unref(vv);
                        if (k_v == null or v_v == null) continue;

                        const key = gdbus.asString(k_v.?) orelse continue;
                        if (mem.eql(u8, key, "Identity")) {
                            const inner = gdbus.g_variant_get_variant(v_v.?);
                            defer gdbus.g_variant_unref(inner);
                            if (gdbus.asString(inner)) |s| {
                                info.identity = try allocator.dupe(u8, s);
                            }
                        }
                    }
                }
            }
        }
    }

    return info;
}

pub fn getActivePlayer(allocator: Allocator, connection: ?*gdbus.GDBusConnection) !PlayerInfo {
    return getActivePlayerFiltered(allocator, connection, null, null);
}

pub fn getActivePlayerFiltered(
    allocator: Allocator,
    connection: ?*gdbus.GDBusConnection,
    target_player: ?[]const u8,
    ignored_players: ?[]const []const u8,
) !PlayerInfo {
    const players = try listPlayers(allocator, connection);
    defer {
        for (players) |p| allocator.free(p);
        allocator.free(players);
    }

    if (players.len == 0) return MprisError.NoPlayers;

    var best_player: ?PlayerInfo = null;
    errdefer if (best_player) |*bp| bp.deinit(allocator);

    for (players) |bus_name| {
        const player_name = if (bus_name.len > MPRIS_PREFIX.len)
            bus_name[MPRIS_PREFIX.len..]
        else
            bus_name;

        if (target_player) |target| {
            if (!mem.eql(u8, player_name, target) and !mem.startsWith(u8, player_name, target)) {
                continue;
            }
        }

        if (ignored_players) |ignored| {
            var skip = false;
            for (ignored) |ig| {
                if (mem.startsWith(u8, player_name, ig)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
        }

        var info = getPlayerInfo(allocator, connection, bus_name) catch continue;

        if (info.status == .playing) {
            if (best_player) |*bp| bp.deinit(allocator);
            return info;
        }

        if (best_player == null) {
            best_player = info;
        } else {
            const current_prio: u8 = switch (best_player.?.status) {
                .playing => 3,
                .paused => 2,
                .stopped => if (best_player.?.metadata.title != null) 1 else 0,
            };
            const new_prio: u8 = switch (info.status) {
                .playing => 3,
                .paused => 2,
                .stopped => if (info.metadata.title != null) 1 else 0,
            };

            if (new_prio > current_prio) {
                best_player.?.deinit(allocator);
                best_player = info;
            } else {
                info.deinit(allocator);
            }
        }
    }

    return best_player orelse MprisError.NoPlayers;
}

pub fn parseMetadata(allocator: Allocator, val: *gdbus.GVariant) Metadata {
    var metadata: Metadata = .{};
    const iter = gdbus.g_variant_iter_new(val) orelse return metadata;
    defer gdbus.g_variant_iter_free(iter);

    while (gdbus.g_variant_iter_next_value(iter)) |entry| {
        defer gdbus.g_variant_unref(entry);
        const k_v = gdbus.g_variant_get_child_value(entry, 0);
        const v_v = gdbus.g_variant_get_child_value(entry, 1);
        defer if (k_v) |kv| gdbus.g_variant_unref(kv);
        defer if (v_v) |vv| gdbus.g_variant_unref(vv);
        if (k_v == null or v_v == null) continue;

        const key = gdbus.asString(k_v.?) orelse continue;
        const inner = gdbus.g_variant_get_variant(v_v.?);
        defer gdbus.g_variant_unref(inner);

        if (mem.eql(u8, key, "xesam:title")) {
            if (gdbus.asString(inner)) |s| metadata.title = allocator.dupe(u8, s) catch null;
        } else if (mem.eql(u8, key, "xesam:artist")) {
            if (gdbus.asString(inner)) |s| {
                metadata.artist = allocator.dupe(u8, s) catch null;
            } else if (mem.startsWith(u8, gdbus.getTypeStr(inner), "a")) {
                var joined: ArrayList(u8) = .empty;
                errdefer joined.deinit(allocator);
                const n = gdbus.g_variant_n_children(inner);
                for (0..n) |i| {
                    const elem = gdbus.g_variant_get_child_value(inner, i);
                    defer gdbus.g_variant_unref(elem);
                    const s = gdbus.asString(elem) orelse continue;
                    if (joined.items.len > 0) joined.appendSlice(allocator, ", ") catch break;
                    joined.appendSlice(allocator, s) catch break;
                }
                if (joined.items.len > 0) {
                    metadata.artist = joined.toOwnedSlice(allocator) catch null;
                } else {
                    joined.deinit(allocator);
                }
            }
        } else if (mem.eql(u8, key, "xesam:albumArtist") and metadata.artist == null) {
            if (gdbus.asString(inner)) |s| {
                metadata.artist = allocator.dupe(u8, s) catch null;
            } else if (mem.startsWith(u8, gdbus.getTypeStr(inner), "a")) {
                const n = gdbus.g_variant_n_children(inner);
                if (n > 0) {
                    const first = gdbus.g_variant_get_child_value(inner, 0);
                    defer gdbus.g_variant_unref(first);
                    if (gdbus.asString(first)) |s| metadata.artist = allocator.dupe(u8, s) catch null;
                }
            }
        } else if (mem.eql(u8, key, "xesam:album")) {
            if (gdbus.asString(inner)) |s| metadata.album = allocator.dupe(u8, s) catch null;
        } else if (mem.eql(u8, key, "mpris:artUrl") or mem.eql(u8, key, "xesam:artUrl") or mem.eql(u8, key, "xesam:url")) {
            if (metadata.art_url == null) {
                if (gdbus.asString(inner)) |s| metadata.art_url = allocator.dupe(u8, s) catch null;
            }
        } else if (mem.eql(u8, key, "mpris:trackid")) {
            if (gdbus.asString(inner)) |s| metadata.track_id = allocator.dupe(u8, s) catch null;
        } else if (mem.eql(u8, key, "mpris:length")) {
            if (gdbus.asInt64(inner)) |l| metadata.length_us = l;
        }
    }

    return metadata;
}

const testing = std.testing;

test "PlaybackStatus.toString" {
    try testing.expectEqualStrings("playing", PlaybackStatus.playing.toString());
    try testing.expectEqualStrings("paused", PlaybackStatus.paused.toString());
    try testing.expectEqualStrings("stopped", PlaybackStatus.stopped.toString());
}

test "LoopStatus.toString" {
    try testing.expectEqualStrings("none", LoopStatus.none.toString());
    try testing.expectEqualStrings("track", LoopStatus.track.toString());
    try testing.expectEqualStrings("playlist", LoopStatus.playlist.toString());
}

test "Metadata.deinit" {
    const allocator = testing.allocator;

    var metadata: Metadata = .{
        .title = try allocator.dupe(u8, "Test Title"),
        .artist = try allocator.dupe(u8, "Test Artist"),
        .album = try allocator.dupe(u8, "Test Album"),
    };

    metadata.deinit(allocator);

    try testing.expectEqual(@as(?[]const u8, null), metadata.title);
    try testing.expectEqual(@as(?[]const u8, null), metadata.artist);
    try testing.expectEqual(@as(?[]const u8, null), metadata.album);
}

test "PlayerInfo.deinit" {
    const allocator = testing.allocator;

    var info: PlayerInfo = .{
        .name = try allocator.dupe(u8, "testplayer"),
        .identity = try allocator.dupe(u8, "Test Player"),
        .status = .playing,
        .metadata = .{
            .title = try allocator.dupe(u8, "Song"),
        },
    };

    info.deinit(allocator);
}

test "parseMetadata with uint64 length and multiple artists" {
    const allocator = testing.allocator;

    const v = gdbus.g_variant_new_parsed(
        @as([*:0]const u8, @ptrCast("{'xesam:title': <'The Catalyst'>, 'xesam:album': <'A Thousand Suns'>, 'mpris:length': <@x 339853000>, 'xesam:artist': <['Linkin Park', 'Chester Bennington']>}")),
    ) orelse return error.VariantParseFailed;
    defer gdbus.g_variant_unref(v);

    var m = parseMetadata(allocator, v);
    defer m.deinit(allocator);

    try testing.expectEqualStrings("The Catalyst", m.title.?);
    try testing.expectEqualStrings("A Thousand Suns", m.album.?);
    try testing.expectEqualStrings("Linkin Park, Chester Bennington", m.artist.?);
    try testing.expectEqual(@as(?i64, 339853000), m.length_us);
}
