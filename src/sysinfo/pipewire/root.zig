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

const Pipewire = @This();

pub const PipewireInfo = @import("PipewireInfo.zig");
pub const PipewireError = @import("PipewireError.zig").PipewireError;

const plume = @import("plume");
const Connection = plume.Connection;
const Proxy = plume.Proxy;
const Value = plume.Value;
const GStr = Value.GStr;
const GVariant = Value.GVariant;

const uProcess = @import("utils").Process;
const findExecutable = uProcess.findExecutable;

const std = @import("std");
const Allocator = mem.Allocator;
const Io = std.Io;
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;
const Environ = process.Environ;
const Map = Environ.Map;

const PULSE_SERVICE: [:0]const u8 = "org.PulseAudio1";
const PULSE_PATH: [:0]const u8 = "/org/pulseaudio/core1";
const PULSE_IFACE: [:0]const u8 = "org.PulseAudio.Core1";

io: Io,
environ_map: *Map,
allocator: Allocator,
connection: *Connection,

pub fn init(io: Io, allocator: Allocator, environ_map: *Map, connection: *Connection) Pipewire {
    return .{
        .io = io,
        .environ_map = environ_map,
        .allocator = allocator,
        .connection = connection,
    };
}

pub fn deinit(self: *Pipewire) void {
    self.* = undefined;
}

pub const VolumeState = struct {
    volume: u8,
    raw_volume: f64,
    muted: bool,
};

/// Parse `wpctl get-volume` or `pactl get-sink-volume` output.
pub fn parseVolumeOutput(output: []const u8) !VolumeState {
    const trimmed = mem.trim(u8, output, &ascii.whitespace);
    if (trimmed.len == 0) return PipewireError.ParseError;

    const is_muted = mem.find(u8, trimmed, "[MUTED]") != null or mem.find(u8, trimmed, "Mute: yes") != null;

    if (mem.find(u8, trimmed, "%")) |pct_idx| {
        var start = pct_idx;
        while (start > 0 and trimmed[start - 1] != ' ' and trimmed[start - 1] != '/' and trimmed[start - 1] != '\t') : (start -= 1) {}
        const pct_str = mem.trim(u8, trimmed[start..pct_idx], &ascii.whitespace);
        if (fmt.parseFloat(f64, pct_str)) |val| {
            const raw_vol = val / 100.0;
            const vol_percent: u8 = @intCast(@min(@as(u64, @intFromFloat(@round(raw_vol * 100.0))), 100));
            return .{
                .volume = vol_percent,
                .raw_volume = raw_vol,
                .muted = is_muted,
            };
        } else |_| {}
    }

    if (mem.find(u8, trimmed, "Volume:")) |idx| {
        const after_vol = trimmed[idx + "Volume:".len ..];
        var tokens = mem.tokenizeAny(u8, after_vol, " \t\r\n/[%]");
        while (tokens.next()) |tok| {
            if (fmt.parseFloat(f64, tok)) |raw_val| {
                const raw_vol = if (raw_val <= 2.0) raw_val else raw_val / 100.0;
                const vol_percent: u8 = @intCast(@min(@as(u64, @intFromFloat(@round(raw_vol * 100.0))), 100));
                return .{
                    .volume = vol_percent,
                    .raw_volume = raw_vol,
                    .muted = is_muted,
                };
            } else |_| {}
        }
    }

    return PipewireError.ParseError;
}

/// Parse node.description from `wpctl inspect` output.
pub fn parseNodeDescription(output: []const u8, allocator: Allocator) ![]const u8 {
    var lines = mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, &ascii.whitespace);
        if (mem.find(u8, trimmed, "node.description =")) |idx| {
            const val_part = mem.trim(u8, trimmed[idx + "node.description =".len ..], &ascii.whitespace);
            const clean_name = mem.trim(u8, val_part, "\"");
            if (clean_name.len > 0) return allocator.dupe(u8, clean_name);
        }
    }

    var lines2 = mem.splitScalar(u8, output, '\n');
    while (lines2.next()) |line| {
        const trimmed = mem.trim(u8, line, &ascii.whitespace);
        if (mem.find(u8, trimmed, "node.name =")) |idx| {
            const val_part = mem.trim(u8, trimmed[idx + "node.name =".len ..], &ascii.whitespace);
            const clean_name = mem.trim(u8, val_part, "\"");
            if (clean_name.len > 0) return allocator.dupe(u8, clean_name);
        }
    }

    return allocator.dupe(u8, "Default Audio Output");
}

/// Fetch volume + mute using wpctl (subprocess), node description via wpctl inspect.
pub fn getAudioInfo(self: Pipewire) !PipewireInfo {
    const vol_output = self.execCommand(&.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }) catch |err| switch (err) {
        else => self.execCommand(&.{ "pactl", "get-sink-volume", "@DEFAULT_SINK@" }) catch return PipewireError.CommandFailed,
    };
    defer self.allocator.free(vol_output);

    const vol_state = try parseVolumeOutput(vol_output);

    const inspect_output = self.execCommand(&.{ "wpctl", "inspect", "@DEFAULT_AUDIO_SINK@" }) catch null;
    defer if (inspect_output) |out| self.allocator.free(out);

    const node_desc = if (inspect_output) |out|
        try parseNodeDescription(out, self.allocator)
    else
        try self.allocator.dupe(u8, "Default Audio Output");

    return .{
        .volume = vol_state.volume,
        .raw_volume = vol_state.raw_volume,
        .muted = vol_state.muted,
        .node_name = node_desc,
        .is_sink = true,
    };
}

/// Fetch source/microphone volume + mute using wpctl/pactl.
pub fn getSourceAudioInfo(self: Pipewire) !PipewireInfo {
    const vol_output = self.execCommand(&.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@" }) catch |err| switch (err) {
        else => self.execCommand(&.{ "pactl", "get-source-volume", "@DEFAULT_SOURCE@" }) catch return PipewireError.CommandFailed,
    };
    defer self.allocator.free(vol_output);

    const vol_state = try parseVolumeOutput(vol_output);

    const inspect_output = self.execCommand(&.{ "wpctl", "inspect", "@DEFAULT_AUDIO_SOURCE@" }) catch null;
    defer if (inspect_output) |out| self.allocator.free(out);

    const node_desc = if (inspect_output) |out|
        try parseNodeDescription(out, self.allocator)
    else
        try self.allocator.dupe(u8, "Default Audio Input");

    return .{
        .volume = vol_state.volume,
        .raw_volume = vol_state.raw_volume,
        .muted = vol_state.muted,
        .node_name = node_desc,
        .is_sink = false,
    };
}

/// Subscribe to PropertiesChanged on the session bus for real-time audio events.
/// Tries PulseAudio DBus interface first (most reliable), falls back to `pactl subscribe` process.
pub fn subscribeViaProcess(self: Pipewire) !process.Child {
    return process.spawn(self.io, .{
        .argv = &.{ "pactl", "subscribe" },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        return process.spawn(self.io, .{
            .argv = &.{"pw-mon"},
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return PipewireError.CommandFailed;
    };
}

fn execCommand(self: Pipewire, argv: []const []const u8) ![]u8 {
    var child = try process.spawn(self.io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    const stdout = try uProcess.readAll(self.io, self.allocator, child.stdout.?);
    errdefer self.allocator.free(stdout);

    const term = try child.wait(self.io);
    if (term != .exited or term.exited != 0) {
        self.allocator.free(stdout);
        return PipewireError.CommandFailed;
    }

    return stdout;
}

const testing = std.testing;

test "parseVolumeOutput wpctl active" {
    const input = "Volume: 0.65";
    const res = try parseVolumeOutput(input);
    try testing.expectEqual(@as(u8, 65), res.volume);
    try testing.expectEqual(false, res.muted);
}

test "parseVolumeOutput wpctl muted" {
    const input = "Volume: 0.35 [MUTED]";
    const res = try parseVolumeOutput(input);
    try testing.expectEqual(@as(u8, 35), res.volume);
    try testing.expectEqual(true, res.muted);
}

test "parseVolumeOutput wpctl zero muted" {
    const input = "Volume: 0.00 [MUTED]";
    const res = try parseVolumeOutput(input);
    try testing.expectEqual(@as(u8, 0), res.volume);
    try testing.expectEqual(true, res.muted);
}

test "parseVolumeOutput pactl active" {
    const input = "Volume: front-left: 26214 /  40% / -23,88 dB,   front-right: 26214 /  40% / -23,88 dB\n        balance 0,00";
    const res = try parseVolumeOutput(input);
    try testing.expectEqual(@as(u8, 40), res.volume);
    try testing.expectEqual(false, res.muted);
}

test "parseNodeDescription" {
    const input =
        \\id 92, type PipeWire:Interface:Node
        \\  * node.description = "WH-CH520 Headphones"
        \\  * node.name = "bluez_output.E8_9E_13_EC_3A_E7.1"
    ;
    const name = try parseNodeDescription(input, testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualSlices(u8, "WH-CH520 Headphones", name);
}
