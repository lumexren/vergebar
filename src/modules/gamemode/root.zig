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

const GamemodeModule = @This();

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

const GAMEMODE_SERVICE = "com.feralinteractive.GameMode";
const GAMEMODE_PATH = "/com/feralinteractive/GameMode";
const GAMEMODE_IFACE = "com.feralinteractive.GameMode";

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_alt: Template,
template_tooltip: ?Template = null,
format: []const u8,
format_alt: []const u8,
glyph: []const u8,
hide_not_running: bool,
dbus_conn: ?*gdbus.GDBusConnection = null,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*GamemodeModule {
    const this = try allocator.create(GamemodeModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "gamemode", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getString("format") orelse "{glyph}";
    const format_alt_str = settings.getString("format-alt") orelse "{glyph} {count}";
    const glyph_str = settings.getString("glyph") orelse "";
    const hide_not_running = settings.getBool("hide-not-running") orelse true;

    var tmpl: Template = try .compile(allocator, format_str);
    errdefer tmpl.deinit();
    var tmpl_alt: Template = try .compile(allocator, format_alt_str);
    errdefer tmpl_alt.deinit();

    const conn = gdbus.getBus(.session);

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .template = tmpl,
        .template_alt = tmpl_alt,
        .template_tooltip = if (base_mod.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null,
        .format = try allocator.dupe(u8, format_str),
        .format_alt = try allocator.dupe(u8, format_alt_str),
        .glyph = try allocator.dupe(u8, glyph_str),
        .hide_not_running = hide_not_running,
        .dbus_conn = conn,
    };

    this.update();
    this.timer_id = gtk.g_timeout_add_seconds(3, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *GamemodeModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template.deinit();
    this.template_alt.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.allocator.free(this.format_alt);
    this.allocator.free(this.glyph);
    if (this.dbus_conn) |c| gdbus.g_object_unref(c);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *GamemodeModule) void {
    var client_count: i32 = 0;
    if (this.dbus_conn) |c| {
        const res = gdbus.callMethodSync(c, GAMEMODE_SERVICE, GAMEMODE_PATH, GAMEMODE_IFACE, "QueryStatus", null);
        if (res) |r| {
            defer gdbus.g_variant_unref(r);
            const child = gdbus.g_variant_get_child_value(r, 0);
            defer if (child) |ch| gdbus.g_variant_unref(ch);
            if (gdbus.asInt64(child)) |cnt| {
                client_count = @intCast(cnt);
            }
        }
    }

    const is_running = client_count > 0;

    if (this.hide_not_running and !is_running) {
        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
        return;
    } else {
        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
    }

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKey("glyph", this.glyph) catch {};
    replacer.addKeyAny("count", client_count) catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = if (client_count > 1)
        this.template_alt.renderBuf(replacer, &render_buf) catch this.format_alt
    else
        this.template.renderBuf(replacer, &render_buf) catch this.format;

    this.base.setText(rendered);

    if (is_running) {
        this.base.addCssClass("running");
        this.base.removeCssClass("not-running");
    } else {
        this.base.addCssClass("not-running");
        this.base.removeCssClass("running");
    }

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [128]u8 = undefined;
        const tt = if (is_running)
            (mem.print(&tt_buf, "GameMode Active ({d} client{s})", .{ client_count, if (client_count > 1) "s" else "" }) catch "GameMode Active")
        else
            "GameMode Inactive";
        this.base.setTooltip(tt);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *GamemodeModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
