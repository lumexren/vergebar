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

pub const GamemodeModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    format_alt: []const u8,
    glyph: []const u8,
    hide_not_running: bool,
    dbus_conn: ?*gtk.GDBusConnection = null,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*GamemodeModule {
        const self = try allocator.create(GamemodeModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "gamemode", settings);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "{glyph}";
        const format_alt_str = settings.getString("format-alt") orelse "{glyph} {count}";
        const glyph_str = settings.getString("glyph") orelse "";
        const hide_not_running = settings.getBool("hide-not-running") orelse true;

        var err: ?*anyopaque = null;
        const conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.session), null, &err);

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, format_str),
            .format_alt = try allocator.dupe(u8, format_alt_str),
            .glyph = try allocator.dupe(u8, glyph_str),
            .hide_not_running = hide_not_running,
            .dbus_conn = conn,
        };

        self.update();
        self.timer_id = gtk.g_timeout_add_seconds(3, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *GamemodeModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.allocator.free(self.format_alt);
        self.allocator.free(self.glyph);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *GamemodeModule) void {
        var client_count: i32 = 0;
        if (self.dbus_conn) |c| {
            var err: ?*anyopaque = null;
            const res = gtk.g_dbus_connection_call_sync(
                c,
                "com.feralinteractive.GameMode",
                "/com/feralinteractive/GameMode",
                "com.feralinteractive.GameMode",
                "QueryStatus",
                null,
                null,
                0,
                500,
                null,
                &err,
            );
            if (res) |r| {
                defer gtk.g_variant_unref(r);
                const child = gtk.g_variant_get_child_value(r, 0);
                if (child) |ch| {
                    defer gtk.g_variant_unref(ch);
                    client_count = gtk.g_variant_get_int32(ch);
                }
            }
        }

        const is_running = client_count > 0;

        if (self.hide_not_running and !is_running) {
            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
            return;
        } else {
            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
        }

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("glyph", self.glyph) catch {};
        replacer.addKeyAny("count", @as(i64, client_count)) catch {};

        const tmpl = if (self.base.alt_active) self.format_alt else self.format;
        const rendered = replacer.render(tmpl) catch tmpl;
        defer if (rendered.ptr != tmpl.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        if (is_running) {
            self.base.addCssClass("running");
            self.base.removeCssClass("stopped");
            var tt_buf: [64]u8 = undefined;
            const tt = mem.print(&tt_buf, "GameMode active ({d} games)", .{client_count}) catch "GameMode active";
            self.base.setTooltip(tt);
        } else {
            self.base.addCssClass("stopped");
            self.base.removeCssClass("running");
            self.base.setTooltip("GameMode inactive");
        }
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *GamemodeModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
