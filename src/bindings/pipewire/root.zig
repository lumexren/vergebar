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

pub extern "c" fn verge_pw_init() c_int;
pub extern "c" fn verge_pw_deinit() void;
pub extern "c" fn verge_pw_get_audio_info(out_volume: *f32, out_muted: *bool, name_buf: [*]u8, name_buf_len: usize) bool;
pub extern "c" fn verge_pw_set_volume(new_percent: f32) c_int;
pub extern "c" fn verge_pw_set_mute(mute: bool) c_int;
pub extern "c" fn verge_pw_get_privacy_info(out_audio_in: *bool, out_screenshare: *bool) bool;

pub const AudioInfo = struct {
    volume: u8,
    raw_volume: f64,
    muted: bool,
    node_name: []const u8,
};

pub fn init() bool {
    return verge_pw_init() == 0;
}

pub fn deinit() void {
    verge_pw_deinit();
}

pub fn getPrivacyInfo(out_audio_in: *bool, out_screenshare: *bool) bool {
    return verge_pw_get_privacy_info(out_audio_in, out_screenshare);
}

pub fn getAudioInfo(allocator: std.mem.Allocator) ?AudioInfo {
    var vol: f32 = 0;
    var muted: bool = false;
    var name_buf: [128]u8 = undefined;

    if (!verge_pw_get_audio_info(&vol, &muted, &name_buf, name_buf.len)) return null;

    const len = std.mem.sliceTo(&name_buf, 0).len;
    const name_slice = allocator.dupe(u8, name_buf[0..len]) catch return null;

    const clamped_vol: u8 = @intCast(@min(@max(@as(i32, @intFromFloat(@round(vol))), 0), 150));

    return .{
        .volume = clamped_vol,
        .raw_volume = @as(f64, vol) / 100.0,
        .muted = muted,
        .node_name = name_slice,
    };
}

pub fn setVolume(percent: f32) bool {
    return verge_pw_set_volume(percent) >= 0;
}

pub fn setMute(mute: bool) bool {
    return verge_pw_set_mute(mute) >= 0;
}
