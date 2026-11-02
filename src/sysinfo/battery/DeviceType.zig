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

pub const DeviceType = enum(u32) {
    unknown = 0,
    line_power = 1,
    battery = 2,
    ups = 3,
    monitor = 4,
    mouse = 5,
    keyboard = 6,
    pda = 7,
    phone = 8,
    media_player = 9,
    tablet = 10,
    computer = 11,
    gaming_input = 12,
    pen = 13,
    touchpad = 14,
    modem = 15,
    network = 16,
    headset = 17,
    speakers = 18,
    headphones = 19,
    video = 20,
    other_audio = 21,
    remote_control = 22,
    printer = 23,
    scanner = 24,
    camera = 25,
    wearable = 26,
    toy = 27,
    bluetooth_generic = 28,
    _,
};
