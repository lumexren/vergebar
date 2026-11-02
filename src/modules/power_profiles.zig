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

pub const PowerProfilesModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    active_profile: []const u8 = "balanced",
    dbus_conn: ?*gtk.GDBusConnection = null,
    sub_id: c_uint = 0,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*PowerProfilesModule {
        const self = try allocator.create(PowerProfilesModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "power-profiles-daemon", settings);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "{icon} {profile}";

        var err: ?*anyopaque = null;
        const conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.system), null, &err);

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, format_str),
            .active_profile = "balanced",
            .dbus_conn = conn,
        };

        if (self.dbus_conn) |c| {
            self.sub_id = gtk.g_dbus_connection_signal_subscribe(
                c,
                "net.hadess.PowerProfiles",
                "org.freedesktop.DBus.Properties",
                "PropertiesChanged",
                "/net/hadess/PowerProfiles",
                "net.hadess.PowerProfiles",
                0,
                @ptrCast(&onPropsChanged),
                self,
                null,
            );
        }

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
        self.timer_id = gtk.g_timeout_add_seconds(5, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *PowerProfilesModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        if (self.dbus_conn) |c| {
            if (self.sub_id != 0) {
                gtk.g_dbus_connection_signal_unsubscribe(c, self.sub_id);
                self.sub_id = 0;
            }
        }
        self.allocator.free(self.format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn cycleProfile(self: *PowerProfilesModule) void {
        const next = if (mem.eql(u8, self.active_profile, "power-saver"))
            "balanced"
        else if (mem.eql(u8, self.active_profile, "balanced"))
            "performance"
        else
            "power-saver";

        const c = self.dbus_conn orelse return;
        var err: ?*anyopaque = null;
        var buf: [128]u8 = undefined;
        const arg_slice = mem.print(&buf, "('net.hadess.PowerProfiles', 'ActiveProfile', <'{s}'>)\x00", .{next}) catch return;
        const arg_z: [*:0]const u8 = @ptrCast(arg_slice.ptr);

        const res = gtk.g_dbus_connection_call_sync(
            c,
            "net.hadess.PowerProfiles",
            "/net/hadess/PowerProfiles",
            "org.freedesktop.DBus.Properties",
            "Set",
            gtk.g_variant_new_parsed(arg_z),
            null,
            0,
            1000,
            null,
            &err,
        );
        if (res) |r| {
            gtk.g_variant_unref(r);
            self.active_profile = next;
            self.update();
        }
    }

    pub fn update(self: *PowerProfilesModule) void {
        const c = self.dbus_conn orelse return;
        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_connection_call_sync(
            c,
            "net.hadess.PowerProfiles",
            "/net/hadess/PowerProfiles",
            "org.freedesktop.DBus.Properties",
            "Get",
            gtk.g_variant_new_parsed("('net.hadess.PowerProfiles', 'ActiveProfile')"),
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
                const val = gtk.g_variant_get_child_value(ch, 0);
                if (val) |v| {
                    defer gtk.g_variant_unref(v);
                    if (gtk.g_variant_get_string(v, null)) |prof_ptr| {
                        const prof = mem.span(prof_ptr);
                        if (mem.eql(u8, prof, "performance")) self.active_profile = "performance" else if (mem.eql(u8, prof, "power-saver")) self.active_profile = "power-saver" else self.active_profile = "balanced";
                    }
                }
            }
        }

        const icon: []const u8 = if (mem.eql(u8, self.active_profile, "performance"))
            ""
        else if (mem.eql(u8, self.active_profile, "power-saver"))
            ""
        else
            "";

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("icon", icon) catch {};
        replacer.addKey("profile", self.active_profile) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        self.base.removeCssClass("performance");
        self.base.removeCssClass("balanced");
        self.base.removeCssClass("power-saver");

        if (mem.eql(u8, self.active_profile, "performance")) {
            self.base.addCssClass("performance");
        } else if (mem.eql(u8, self.active_profile, "power-saver")) {
            self.base.addCssClass("power-saver");
        } else {
            self.base.addCssClass("balanced");
        }

        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "Power Profile: {s}", .{self.active_profile}) catch "Power Profile";
        self.base.setTooltip(tt);
    }
};

fn onPropsChanged(
    conn: ?*gtk.GDBusConnection,
    sender: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    signal_name: ?[*:0]const u8,
    parameters: ?*gtk.GVariant,
    user_data: gtk.gpointer,
) callconv(.c) void {
    _ = conn;
    _ = sender;
    _ = object_path;
    _ = interface_name;
    _ = signal_name;
    _ = parameters;
    const self: *PowerProfilesModule = @ptrCast(@alignCast(user_data orelse return));
    self.update();
}

fn onClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const self: *PowerProfilesModule = @ptrCast(@alignCast(user_data orelse return));
    self.cycleProfile();
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *PowerProfilesModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
