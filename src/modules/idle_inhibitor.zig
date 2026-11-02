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

pub const IdleInhibitorModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    icon_activated: []const u8,
    icon_deactivated: []const u8,
    is_active: bool = false,
    inhibit_cookie: u32 = 0,
    dbus_conn: ?*gtk.GDBusConnection = null,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*IdleInhibitorModule {
        const self = try allocator.create(IdleInhibitorModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "idle_inhibitor", settings);
        errdefer base_mod.deinit();

        var icon_act: []const u8 = "";
        var icon_deact: []const u8 = "";

        if (settings.value == .object and settings.value.object.get("format-icons") != null) {
            const icons = settings.value.object.get("format-icons").?;
            if (icons == .object) {
                if (icons.object.get("activated")) |act| {
                    if (act == .string) icon_act = act.string;
                }
                if (icons.object.get("deactivated")) |deact| {
                    if (deact == .string) icon_deact = deact.string;
                }
            }
        }

        const format_str = settings.getString("format") orelse "{icon}";

        var err: ?*anyopaque = null;
        const conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.session), null, &err);

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, format_str),
            .icon_activated = try allocator.dupe(u8, icon_act),
            .icon_deactivated = try allocator.dupe(u8, icon_deact),
            .is_active = false,
            .dbus_conn = conn,
        };

        if (self.base.button) |btn| {
            _ = gtk.g_signal_connect_data(
                btn,
                "clicked",
                @ptrCast(&onClicked),
                self,
                null,
                0,
            );
        }

        self.update();
        return self;
    }

    pub fn deinit(self: *IdleInhibitorModule) void {
        if (self.is_active) {
            self.releaseInhibition();
        }
        self.allocator.free(self.format);
        self.allocator.free(self.icon_activated);
        self.allocator.free(self.icon_deactivated);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn toggle(self: *IdleInhibitorModule) void {
        if (self.is_active) {
            self.releaseInhibition();
            self.is_active = false;
        } else {
            self.requestInhibition();
            self.is_active = true;
        }
        self.update();
    }

    fn requestInhibition(self: *IdleInhibitorModule) void {
        const c = self.dbus_conn orelse return;
        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_connection_call_sync(
            c,
            "org.freedesktop.ScreenSaver",
            "/org/freedesktop/ScreenSaver",
            "org.freedesktop.ScreenSaver",
            "Inhibit",
            gtk.g_variant_new_parsed("('vergebar', 'User requested idle inhibition')"),
            null,
            0,
            1000,
            null,
            &err,
        );
        if (res) |r| {
            defer gtk.g_variant_unref(r);
            const child = gtk.g_variant_get_child_value(r, 0);
            if (child) |ch| {
                defer gtk.g_variant_unref(ch);
                self.inhibit_cookie = gtk.g_variant_get_uint32(ch);
            }
        }
    }

    fn releaseInhibition(self: *IdleInhibitorModule) void {
        const c = self.dbus_conn orelse return;
        if (self.inhibit_cookie != 0) {
            var err: ?*anyopaque = null;
            const res = gtk.g_dbus_connection_call_sync(
                c,
                "org.freedesktop.ScreenSaver",
                "/org/freedesktop/ScreenSaver",
                "org.freedesktop.ScreenSaver",
                "UnInhibit",
                gtk.g_variant_new_parsed("(%u,)", self.inhibit_cookie),
                null,
                0,
                1000,
                null,
                &err,
            );
            if (res) |r| gtk.g_variant_unref(r);
            self.inhibit_cookie = 0;
        }
    }

    pub fn update(self: *IdleInhibitorModule) void {
        const icon = if (self.is_active) self.icon_activated else self.icon_deactivated;
        const status = if (self.is_active) "activated" else "deactivated";

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", icon) catch {};
        replacer.addKey("status", status) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        if (self.is_active) {
            self.base.addCssClass("activated");
            self.base.removeCssClass("deactivated");
            self.base.setTooltip("Idle inhibitor: active (screen sleep disabled)");
        } else {
            self.base.addCssClass("deactivated");
            self.base.removeCssClass("activated");
            self.base.setTooltip("Idle inhibitor: inactive");
        }
    }
};

fn onClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const self: *IdleInhibitorModule = @ptrCast(@alignCast(user_data orelse return));
    self.toggle();
}
