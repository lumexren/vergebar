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

const PowerProfilesModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const gdbus = @import("bindings").gdbus;
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const Template = @import("utils").Template;

const POWER_PROFILES_SERVICE = "net.hadess.PowerProfiles";
const POWER_PROFILES_PATH = "/net/hadess/PowerProfiles";
const POWER_PROFILES_IFACE = "net.hadess.PowerProfiles";

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
format: []const u8,
active_profile: []const u8 = "balanced",
dbus_conn: ?*gdbus.GDBusConnection = null,
sub_id: c_uint = 0,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*PowerProfilesModule {
    const this = try allocator.create(PowerProfilesModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "power-profiles-daemon", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getString("format") orelse "{icon} {profile}";
    var tmpl: Template = try .compile(allocator, format_str);
    errdefer tmpl.deinit();

    const conn = gdbus.getBus(.system);

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .template = tmpl,
        .template_tooltip = if (base_mod.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null,
        .format = try allocator.dupe(u8, format_str),
        .active_profile = "balanced",
        .dbus_conn = conn,
    };

    if (this.dbus_conn) |c| {
        this.sub_id = gtk.g_dbus_connection_signal_subscribe(
            @ptrCast(c),
            POWER_PROFILES_SERVICE,
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            POWER_PROFILES_PATH,
            POWER_PROFILES_IFACE,
            0,
            @ptrCast(&onPropsChanged),
            this,
            null,
        );
    }

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
    this.timer_id = gtk.g_timeout_add_seconds(5, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *PowerProfilesModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    if (this.dbus_conn) |c| {
        if (this.sub_id != 0) {
            gtk.g_dbus_connection_signal_unsubscribe(@ptrCast(c), this.sub_id);
            this.sub_id = 0;
        }
        gdbus.g_object_unref(c);
    }
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn cycleProfile(this: *PowerProfilesModule) void {
    const next = if (mem.eql(u8, this.active_profile, "power-saver"))
        "balanced"
    else if (mem.eql(u8, this.active_profile, "balanced"))
        "performance"
    else
        "power-saver";

    const c = this.dbus_conn orelse return;
    var buf: [128]u8 = undefined;
    const arg_z = mem.printSentinel(&buf, "('net.hadess.PowerProfiles', 'ActiveProfile', <'{s}'>)", .{next}, 0) catch return;

    const res = gdbus.callMethodSync(
        c,
        POWER_PROFILES_SERVICE,
        POWER_PROFILES_PATH,
        "org.freedesktop.DBus.Properties",
        "Set",
        gdbus.g_variant_new_parsed(arg_z),
    );
    if (res) |r| {
        gdbus.g_variant_unref(r);
        this.active_profile = next;
        this.update();
    }
}

pub fn update(this: *PowerProfilesModule) void {
    const c = this.dbus_conn orelse return;

    if (gdbus.getPropertySync(c, POWER_PROFILES_SERVICE, POWER_PROFILES_PATH, POWER_PROFILES_IFACE, "ActiveProfile")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asString(v)) |prof| {
            if (mem.eql(u8, prof, "performance"))
                this.active_profile = "performance"
            else if (mem.eql(u8, prof, "power-saver"))
                this.active_profile = "power-saver"
            else
                this.active_profile = "balanced";
        }
    }

    const icon: []const u8 = if (mem.eql(u8, this.active_profile, "performance"))
        ""
    else if (mem.eql(u8, this.active_profile, "power-saver"))
        ""
    else
        "";

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKey("icon", icon) catch {};
    replacer.addKey("profile", this.active_profile) catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = this.template.renderBuf(replacer, &render_buf) catch this.format;
    this.base.setText(rendered);

    this.base.removeCssClass("performance");
    this.base.removeCssClass("balanced");
    this.base.removeCssClass("power-saver");

    if (mem.eql(u8, this.active_profile, "performance")) {
        this.base.addCssClass("performance");
    } else if (mem.eql(u8, this.active_profile, "power-saver")) {
        this.base.addCssClass("power-saver");
    } else {
        this.base.addCssClass("balanced");
    }

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "Power Profile: {s}", .{this.active_profile}) catch "Power Profile";
        this.base.setTooltip(tt);
    }
}

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
    const this: *PowerProfilesModule = @ptrCast(@alignCast(user_data orelse return));
    const params = parameters orelse return;

    const child = gdbus.g_variant_get_child_value(@ptrCast(params), 1) orelse return;
    defer gdbus.g_variant_unref(child);

    const iter = gdbus.g_variant_iter_new(child) orelse return;
    defer gdbus.g_variant_iter_free(iter);

    while (gdbus.g_variant_iter_next_value(iter)) |entry| {
        defer gdbus.g_variant_unref(entry);
        const k_val = gdbus.g_variant_get_child_value(entry, 0);
        defer if (k_val) |kv| gdbus.g_variant_unref(kv);
        if (k_val == null) continue;

        if (gdbus.asString(k_val)) |key| {
            if (mem.eql(u8, key, "ActiveProfile")) {
                const v_box = gdbus.g_variant_get_child_value(entry, 1);
                defer if (v_box) |vb| gdbus.g_variant_unref(vb);
                if (v_box) |vb| {
                    const v_actual = gdbus.g_variant_get_variant(vb);
                    defer gdbus.g_variant_unref(v_actual);
                    if (gdbus.asString(v_actual)) |prof| {
                        if (mem.eql(u8, prof, "performance"))
                            this.active_profile = "performance"
                        else if (mem.eql(u8, prof, "power-saver"))
                            this.active_profile = "power-saver"
                        else
                            this.active_profile = "balanced";
                        this.update();
                    }
                }
            }
        }
    }
}

fn onClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *PowerProfilesModule = @ptrCast(@alignCast(user_data orelse return));
    this.cycleProfile();
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *PowerProfilesModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
