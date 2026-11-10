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

const IdleInhibitorModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
format: []const u8,
icon_activated: []const u8,
icon_deactivated: []const u8,
is_active: bool = false,
inhibit_cookie: u32 = 0,
dbus_conn: ?*gtk.GDBusConnection = null,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*IdleInhibitorModule {
    const this = try allocator.create(IdleInhibitorModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "idle_inhibitor", settings);
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

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .format = try allocator.dupe(u8, format_str),
        .icon_activated = try allocator.dupe(u8, icon_act),
        .icon_deactivated = try allocator.dupe(u8, icon_deact),
        .is_active = false,
        .dbus_conn = conn,
    };

    if (this.base.button) |btn| {
        _ = gtk.g_signal_connect_data(
            btn,
            "clicked",
            @ptrCast(&onClicked),
            this,
            null,
            0,
        );
    }

    this.update();
    return this;
}

pub fn deinit(this: *IdleInhibitorModule) void {
    if (this.is_active) {
        this.releaseInhibition();
    }
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.allocator.free(this.icon_activated);
    this.allocator.free(this.icon_deactivated);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn toggle(this: *IdleInhibitorModule) void {
    if (this.is_active) {
        this.releaseInhibition();
        this.is_active = false;
    } else {
        this.requestInhibition();
        this.is_active = true;
    }
    this.update();
}

fn requestInhibition(this: *IdleInhibitorModule) void {
    const c = this.dbus_conn orelse return;
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
            this.inhibit_cookie = gtk.g_variant_get_uint32(ch);
        }
    }
}

fn releaseInhibition(this: *IdleInhibitorModule) void {
    const c = this.dbus_conn orelse return;
    if (this.inhibit_cookie != 0) {
        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_connection_call_sync(
            c,
            "org.freedesktop.ScreenSaver",
            "/org/freedesktop/ScreenSaver",
            "org.freedesktop.ScreenSaver",
            "UnInhibit",
            gtk.g_variant_new_parsed("(%u,)", this.inhibit_cookie),
            null,
            0,
            1000,
            null,
            &err,
        );
        if (res) |r| gtk.g_variant_unref(r);
        this.inhibit_cookie = 0;
    }
}

pub fn update(this: *IdleInhibitorModule) void {
    const icon = if (this.is_active) this.icon_activated else this.icon_deactivated;
    const status = if (this.is_active) "activated" else "deactivated";

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKey("icon", icon) catch {};
    replacer.addKey("status", status) catch {};

    const rendered = replacer.render(this.format) catch this.format;
    defer if (rendered.ptr != this.format.ptr) this.allocator.free(rendered);

    this.base.setText(rendered);

    if (this.is_active) {
        this.base.addCssClass("activated");
        this.base.removeCssClass("deactivated");
        this.base.setTooltip("Idle inhibitor: active (screen sleep disabled)");
    } else {
        this.base.addCssClass("deactivated");
        this.base.removeCssClass("activated");
        this.base.setTooltip("Idle inhibitor: inactive");
    }
}

fn onClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *IdleInhibitorModule = @ptrCast(@alignCast(user_data orelse return));
    this.toggle();
}
