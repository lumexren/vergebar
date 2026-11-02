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

const plume = @import("plume");
const Connection = plume.Connection;
const Proxy = plume.Proxy;
const Value = plume.Value;
const GStr = Value.GStr;
const GVariant = Value.GVariant;

const std = @import("std");
const ArrayList = std.ArrayList;
const meta = std.meta;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const math = std.math;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;
const StringHashMap = std.StringHashMap;

pub const MPRIS_PREFIX = "org.mpris.MediaPlayer2.";
pub const MPRIS_PATH: [:0]const u8 = "/org/mpris/MediaPlayer2";
pub const PLAYER_IFACE: [:0]const u8 = "org.mpris.MediaPlayer2.Player";
pub const ROOT_IFACE: [:0]const u8 = "org.mpris.MediaPlayer2";

pub fn listPlayers(allocator: Allocator, connection: *Connection) ![][]const u8 {
    var dbus_proxy: Proxy = .init(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    );

    var res = dbus_proxy.call("ListNames", .{}) catch return MprisError.ConnectionFailed;
    defer res.deinit();

    const names = res.expectAlloc([]GStr) catch return MprisError.InvalidResponse;
    defer {
        for (names) |n| allocator.free(n.s);
        allocator.free(names);
    }

    var players: ArrayList([]const u8) = .empty;
    errdefer {
        for (players.items) |p| allocator.free(p);
        players.deinit(allocator);
    }

    for (names) |name| {
        if (mem.startsWith(u8, name.s, MPRIS_PREFIX)) {
            try players.append(allocator, try allocator.dupe(u8, name.s));
        }
    }

    return players.toOwnedSlice(allocator);
}

pub fn getPlayerInfo(allocator: Allocator, connection: *Connection, bus_name: []const u8) !PlayerInfo {
    const player_name = if (bus_name.len > MPRIS_PREFIX.len)
        bus_name[MPRIS_PREFIX.len..]
    else
        bus_name;

    var info = PlayerInfo{
        .name = try allocator.dupe(u8, player_name),
    };
    errdefer info.deinit(allocator);

    const bus_name_z = try allocator.printSentinel("{s}", .{bus_name}, 0);
    defer allocator.free(bus_name_z);

    const root_proxy: Proxy = .init(connection, bus_name_z, MPRIS_PATH, ROOT_IFACE);
    const player_proxy: Proxy = .init(connection, bus_name_z, MPRIS_PATH, PLAYER_IFACE);

    var arena: ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    if (player_proxy.rawCall("org.freedesktop.DBus.Properties", "GetAll", .{
        GStr.new(PLAYER_IFACE),
    })) |*res| {
        var call_res = res.*;
        defer call_res.deinit();

        const PropsMap = StringHashMap(GVariant);
        var dec: plume.Decoder = .fromMessage(arena_alloc, call_res.message);
        if (dec.decodeAlloc(PropsMap)) |dict| {
            var it = dict.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                const inner = if (val == .variant) val.variant.* else val;

                if (mem.eql(u8, key, "PlaybackStatus")) {
                    if (inner == .string) {
                        if (mem.eql(u8, inner.string.s, "Playing")) {
                            info.status = .playing;
                        } else if (mem.eql(u8, inner.string.s, "Paused")) {
                            info.status = .paused;
                        } else if (mem.eql(u8, inner.string.s, "Stopped")) {
                            info.status = .stopped;
                        }
                    }
                } else if (mem.eql(u8, key, "LoopStatus")) {
                    if (inner == .string) {
                        if (mem.eql(u8, inner.string.s, "None")) {
                            info.loop_status = .none;
                        } else if (mem.eql(u8, inner.string.s, "Track")) {
                            info.loop_status = .track;
                        } else if (mem.eql(u8, inner.string.s, "Playlist")) {
                            info.loop_status = .playlist;
                        }
                    }
                } else if (mem.eql(u8, key, "Shuffle")) {
                    if (inner == .boolean) info.shuffle = inner.boolean;
                } else if (mem.eql(u8, key, "CanControl")) {
                    if (inner == .boolean) info.can_control = inner.boolean;
                } else if (mem.eql(u8, key, "CanGoNext")) {
                    if (inner == .boolean) info.can_go_next = inner.boolean;
                } else if (mem.eql(u8, key, "CanGoPrevious")) {
                    if (inner == .boolean) info.can_go_previous = inner.boolean;
                } else if (mem.eql(u8, key, "CanPlay")) {
                    if (inner == .boolean) info.can_play = inner.boolean;
                } else if (mem.eql(u8, key, "CanPause")) {
                    if (inner == .boolean) info.can_pause = inner.boolean;
                } else if (mem.eql(u8, key, "CanSeek")) {
                    if (inner == .boolean) info.can_seek = inner.boolean;
                } else if (mem.eql(u8, key, "Volume")) {
                    switch (inner) {
                        .double => |d| info.volume = d,
                        .int64 => |d| info.volume = @floatFromInt(d),
                        .uint64 => |d| info.volume = @floatFromInt(d),
                        else => {},
                    }
                } else if (mem.eql(u8, key, "Position")) {
                    switch (inner) {
                        .int64 => |p| info.position_us = p,
                        .uint64 => |p| info.position_us = @intCast(@min(p, @as(u64, math.maxInt(i64)))),
                        else => {},
                    }
                } else if (mem.eql(u8, key, "Metadata")) {
                    info.metadata = parseMetadata(allocator, inner);
                }
            }
        } else |_| {}
    } else |_| {
        if (player_proxy.getProperty(GVariant, "PlaybackStatus")) |v| {
            var mv = v;
            defer mv.deinit(allocator);
            if (v == .string) {
                if (mem.eql(u8, v.string.s, "Playing")) info.status = .playing else if (mem.eql(u8, v.string.s, "Paused")) info.status = .paused else if (mem.eql(u8, v.string.s, "Stopped")) info.status = .stopped;
            }
        } else |_| {}

        info.metadata = getMetadataProperty(allocator, player_proxy);
    }

    if (root_proxy.rawCall("org.freedesktop.DBus.Properties", "GetAll", .{
        GStr.new(ROOT_IFACE),
    })) |*res| {
        var call_res = res.*;
        defer call_res.deinit();

        const PropsMap = StringHashMap(GVariant);
        var dec: plume.Decoder = .fromMessage(arena_alloc, call_res.message);
        if (dec.decodeAlloc(PropsMap)) |dict| {
            if (dict.get("Identity")) |id_v| {
                const inner = if (id_v == .variant) id_v.variant.* else id_v;
                if (inner == .string) {
                    info.identity = try allocator.dupe(u8, inner.string.s);
                }
            }
        } else |_| {}
    } else |_| {}

    return info;
}

pub fn getActivePlayer(allocator: Allocator, connection: *Connection) !PlayerInfo {
    return getActivePlayerFiltered(allocator, connection, null, null);
}

pub fn getActivePlayerFiltered(
    allocator: Allocator,
    connection: *Connection,
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

fn parseMetadata(allocator: Allocator, val: GVariant) Metadata {
    var metadata: Metadata = .{};
    const dict = if (val == .variant) val.variant.* else val;
    if (dict != .dict) return metadata;

    var it = dict.dict.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        const inner = if (v == .variant) v.variant.* else v;

        if (mem.eql(u8, key, "xesam:title")) {
            if (inner == .string) metadata.title = allocator.dupe(u8, inner.string.s) catch null;
        } else if (mem.eql(u8, key, "xesam:artist")) {
            if (inner == .array and inner.array.len > 0) {
                var joined: ArrayList(u8) = .empty;
                errdefer joined.deinit(allocator);
                for (inner.array) |elem| {
                    const s = if (elem == .variant) elem.variant.* else elem;
                    if (s == .string) {
                        if (joined.items.len > 0) joined.appendSlice(allocator, ", ") catch break;
                        joined.appendSlice(allocator, s.string.s) catch break;
                    }
                }
                if (joined.items.len > 0) {
                    metadata.artist = joined.toOwnedSlice(allocator) catch null;
                } else {
                    joined.deinit(allocator);
                }
            } else if (inner == .string) {
                metadata.artist = allocator.dupe(u8, inner.string.s) catch null;
            }
        } else if (mem.eql(u8, key, "xesam:albumArtist") and metadata.artist == null) {
            if (inner == .array and inner.array.len > 0) {
                const first = inner.array[0];
                const s = if (first == .variant) first.variant.* else first;
                if (s == .string) metadata.artist = allocator.dupe(u8, s.string.s) catch null;
            } else if (inner == .string) {
                metadata.artist = allocator.dupe(u8, inner.string.s) catch null;
            }
        } else if (mem.eql(u8, key, "xesam:album")) {
            if (inner == .string) metadata.album = allocator.dupe(u8, inner.string.s) catch null;
        } else if (mem.eql(u8, key, "mpris:artUrl") or mem.eql(u8, key, "xesam:artUrl") or mem.eql(u8, key, "xesam:url")) {
            if (inner == .string and metadata.art_url == null) metadata.art_url = allocator.dupe(u8, inner.string.s) catch null;
        } else if (mem.eql(u8, key, "mpris:trackid")) {
            if (inner == .string or inner == .object_path) {
                const s = if (inner == .object_path) inner.object_path.s else inner.string.s;
                metadata.track_id = allocator.dupe(u8, s) catch null;
            }
        } else if (mem.eql(u8, key, "mpris:length")) {
            switch (inner) {
                .int64 => |l| metadata.length_us = l,
                .uint64 => |l| metadata.length_us = @intCast(@min(l, @as(u64, math.maxInt(i64)))),
                .int32 => |l| metadata.length_us = l,
                .uint32 => |l| metadata.length_us = l,
                else => {},
            }
        }
    }

    return metadata;
}

fn getMetadataProperty(allocator: Allocator, player_proxy: Proxy) Metadata {
    const metadata: Metadata = .{};

    var arena: ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var res = player_proxy.rawCall("org.freedesktop.DBus.Properties", "Get", .{
        GStr.new(player_proxy.interface),
        GStr.new("Metadata"),
    }) catch return metadata;
    defer res.deinit();

    var dec: plume.Decoder = .fromMessage(arena.allocator(), res.message);
    const v = dec.decodeAlloc(GVariant) catch return metadata;

    return parseMetadata(allocator, v);
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

    var metadata = Metadata{
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

    var info = PlayerInfo{
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

    var dict = StringHashMap(GVariant).init(allocator);
    defer dict.deinit();

    try dict.put("xesam:title", .{ .string = .{ .s = "The Catalyst" } });
    try dict.put("xesam:album", .{ .string = .{ .s = "A Thousand Suns" } });
    try dict.put("mpris:length", .{ .uint64 = 339853000 });

    var artists = [_]GVariant{
        .{ .string = .{ .s = "Linkin Park" } },
        .{ .string = .{ .s = "Chester Bennington" } },
    };
    try dict.put("xesam:artist", .{ .array = &artists });

    var m = parseMetadata(allocator, .{ .dict = dict });
    defer m.deinit(allocator);

    try testing.expectEqualStrings("The Catalyst", m.title.?);
    try testing.expectEqualStrings("A Thousand Suns", m.album.?);
    try testing.expectEqualStrings("Linkin Park, Chester Bennington", m.artist.?);
    try testing.expectEqual(@as(?i64, 339853000), m.length_us);
}
