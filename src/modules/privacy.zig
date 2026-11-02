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
const mem = std.mem;
const Allocator = mem.Allocator;
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

const Context = @import("utils").Context;

pub const PrivacyModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*PrivacyModule {
        const self = try allocator.create(PrivacyModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "privacy", settings);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "{screenshare} {audio_in}";

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, format_str),
        };

        self.update();
        self.timer_id = gtk.g_timeout_add_seconds(2, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *PrivacyModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *PrivacyModule) void {
        var mic_active = false;
        var screen_active = false;

        if (Context.runShellAlloc(self.allocator, "pw-dump 2>/dev/null")) |dump_out| {
            defer self.allocator.free(dump_out);
            if (mem.find(u8, dump_out, "\"media.class\": \"Stream/Input/Audio\"") != null) {
                mic_active = true;
            }
            if (mem.find(u8, dump_out, "\"media.class\": \"Stream/Input/Video\"") != null or
                mem.find(u8, dump_out, "xdg-desktop-portal") != null)
            {
                screen_active = true;
            }
        } else |_| {}

        const is_active = mic_active or screen_active;
        if (!is_active) {
            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
            return;
        } else {
            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
        }

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("audio_in", if (mic_active) "" else "") catch {};
        replacer.addKey("screenshare", if (screen_active) "󰍹" else "") catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        if (mic_active) self.base.addCssClass("audio-in") else self.base.removeCssClass("audio-in");
        if (screen_active) self.base.addCssClass("screenshare") else self.base.removeCssClass("screenshare");

        self.base.setTooltip("Privacy: Media streaming or recording in progress");
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *PrivacyModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
