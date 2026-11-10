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

const PrivacyModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const pipewire = @import("bindings").pipewire;
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const sh = @import("utils").sh;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
format: []const u8,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*PrivacyModule {
    const this = try allocator.create(PrivacyModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "privacy", settings);
    errdefer base_mod.deinit();

    _ = pipewire.init();

    const format_str = settings.getString("format") orelse "{screenshare} {audio_in}";

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .format = try allocator.dupe(u8, format_str),
    };

    this.update();
    this.timer_id = gtk.g_timeout_add_seconds(2, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *PrivacyModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *PrivacyModule) void {
    var mic_active = false;
    var screen_active = false;

    // Zero-subprocess check via native PipeWire thread loop & registry
    if (!pipewire.getPrivacyInfo(&mic_active, &screen_active)) {
        // Fallback: pw-dump if native PipeWire loop is unavailable
        if (sh.runAlloc(this.base.io, this.allocator, "pw-dump 2>/dev/null")) |dump_out| {
            defer this.allocator.free(dump_out);
            if (mem.find(u8, dump_out, "\"media.class\": \"Stream/Input/Audio\"") != null) {
                mic_active = true;
            }
            if (mem.find(u8, dump_out, "\"media.class\": \"Stream/Input/Video\"") != null or
                mem.find(u8, dump_out, "xdg-desktop-portal") != null)
            {
                screen_active = true;
            }
        } else |_| {}
    }

    const is_active = mic_active or screen_active;
    if (!is_active) {
        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
        return;
    } else {
        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
    }

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKey("audio_in", if (mic_active) "" else "") catch {};
    replacer.addKey("screenshare", if (screen_active) "󰍹" else "") catch {};

    const rendered = replacer.render(this.format) catch this.format;
    defer if (rendered.ptr != this.format.ptr) this.allocator.free(rendered);

    this.base.setText(rendered);

    if (mic_active) this.base.addCssClass("audio-in") else this.base.removeCssClass("audio-in");
    if (screen_active) this.base.addCssClass("screenshare") else this.base.removeCssClass("screenshare");

    this.base.setTooltip("Privacy: Media streaming or recording in progress");
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *PrivacyModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
