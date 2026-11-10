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

const DndModule = @This();

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;
const sh = utils.sh;
const gdbus = @import("bindings").gdbus;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon_normal: []const u8,
icon_dnd: []const u8,
icon_none: []const u8,
interval_sec: u32,
timer_id: u32 = 0,
is_dnd: bool = false,
notification_count: u32 = 0,
dbus_conn: ?*gdbus.GDBusConnection = null,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*DndModule {
    const this = try allocator.create(DndModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "dnd", settings);
    errdefer this.base.deinit();

    this.allocator = allocator;
    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getString("format") orelse "{icon}  {count}";
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.icon_normal = try allocator.dupe(u8, settings.getString("icon-normal") orelse "󰂚");
    this.icon_dnd = try allocator.dupe(u8, settings.getString("icon-dnd") orelse "󰂛");
    this.icon_none = try allocator.dupe(u8, settings.getString("icon-none") orelse "󰂜");

    this.interval_sec = settings.getOr(u32, "interval", 3);
    if (this.interval_sec == 0) this.interval_sec = 3;

    this.dbus_conn = gdbus.getBus(.session);

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *DndModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }

    if (this.dbus_conn) |c| gdbus.g_object_unref(c);
    this.allocator.free(this.icon_normal);
    this.allocator.free(this.icon_dnd);
    this.allocator.free(this.icon_none);
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();

    const alloc = this.base.allocator;
    this.base.deinit();
    alloc.destroy(this);
}

pub fn toggleDnd(this: *DndModule) void {
    const conn = this.dbus_conn;
    if (conn) |c| {
        if (gdbus.callMethodSync(c, "org.erikreider.swaync", "/org/erikreider/swaync", "org.erikreider.swaync", "ToggleDnd", null)) |res| {
            gdbus.g_variant_unref(res);
            this.update();
            return;
        }

        if (gdbus.callMethodSync(c, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.dunstproject.cmd0", "NotificationPauseToggle", null)) |res| {
            gdbus.g_variant_unref(res);
            this.update();
            return;
        }

        var mako_buf: [64]u8 = undefined;
        const target_mode = if (this.is_dnd) "default" else "do-not-disturb";
        const mako_arg = mem.printSentinel(&mako_buf, "('{s}',)", .{target_mode}, 0) catch "";
        if (mako_arg.len > 0) {
            if (gdbus.g_variant_new_parsed(mako_arg)) |parsed| {
                if (gdbus.callMethodSync(c, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "fr.emersion.Mako", "SetMode", parsed)) |res| {
                    gdbus.g_variant_unref(res);
                    this.update();
                    return;
                }
            }
        }
    }

    const io = this.base.io;
    var probe_buf: [32]u8 = undefined;
    if (sh.runTrimBuf(io, "command -v swaync-client", &probe_buf).len > 0) {
        _ = sh.runBuf(io, "swaync-client -d -s", &probe_buf);
    } else if (sh.runTrimBuf(io, "command -v dunstctl", &probe_buf).len > 0) {
        _ = sh.runBuf(io, "dunstctl set-paused toggle", &probe_buf);
    } else if (sh.runTrimBuf(io, "command -v makoctl", &probe_buf).len > 0) {
        _ = sh.runBuf(io, "makoctl mode -t do-not-disturb", &probe_buf);
    }

    this.update();
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    const this: *DndModule = @ptrCast(@alignCast(user_data orelse return false));
    if (btn_num == 1) {
        this.toggleDnd();
        return true;
    } else if (btn_num == 3) {
        if (this.dbus_conn) |c| {
            if (gdbus.callMethodSync(c, "org.erikreider.swaync", "/org/erikreider/swaync", "org.erikreider.swaync", "ToggleWidget", null)) |res| {
                gdbus.g_variant_unref(res);
                return true;
            }
        }
        var buf: [32]u8 = undefined;
        if (sh.runTrimBuf(this.base.io, "command -v swaync-client", &buf).len > 0) {
            _ = sh.runBuf(this.base.io, "swaync-client -t -sw", &buf);
            return true;
        }
    }
    return false;
}

pub fn update(this: *DndModule) void {
    var dnd_active = false;
    var count: u32 = 0;

    if (this.dbus_conn) |c| {
        if (gdbus.getPropertySync(c, "org.erikreider.swaync", "/org/erikreider/swaync", "org.erikreider.swaync", "dnd")) |v| {
            defer gdbus.g_variant_unref(v);
            if (gdbus.asBoolean(v)) |b| dnd_active = b;
            if (gdbus.getPropertySync(c, "org.erikreider.swaync", "/org/erikreider/swaync", "org.erikreider.swaync", "count")) |cnt_v| {
                defer gdbus.g_variant_unref(cnt_v);
                if (gdbus.asUint32(cnt_v)) |cnt| count = cnt;
            }
            this.renderState(dnd_active, count);
            return;
        }

        if (gdbus.callMethodSync(c, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.dunstproject.cmd0", "NotificationIsPaused", null)) |res| {
            defer gdbus.g_variant_unref(res);
            if (gdbus.g_variant_get_child_value(res, 0)) |val| {
                defer gdbus.g_variant_unref(val);
                if (gdbus.asBoolean(val)) |b| dnd_active = b;
            }
            if (gdbus.callMethodSync(c, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.dunstproject.cmd0", "NotificationCount", null)) |cnt_res| {
                defer gdbus.g_variant_unref(cnt_res);
                if (gdbus.g_variant_get_child_value(cnt_res, 0)) |waiting_val| {
                    defer gdbus.g_variant_unref(waiting_val);
                    if (gdbus.asUint32(waiting_val)) |w| count = w;
                }
            }
            this.renderState(dnd_active, count);
            return;
        }

        if (gdbus.getPropertySync(c, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Inhibited")) |v| {
            defer gdbus.g_variant_unref(v);
            if (gdbus.asBoolean(v)) |b| {
                dnd_active = b;
                this.renderState(dnd_active, 0);
                return;
            }
        }
    }

    const io = this.base.io;
    var buf: [128]u8 = undefined;
    if (sh.runTrimBuf(io, "command -v swaync-client", &buf).len > 0) {
        var out_buf: [64]u8 = undefined;
        const dnd_res = sh.runTrimBuf(io, "swaync-client -D", &out_buf);
        if (mem.eql(u8, dnd_res, "true")) dnd_active = true;

        var count_buf: [64]u8 = undefined;
        const count_res = sh.runTrimBuf(io, "swaync-client -c", &count_buf);
        if (fmt.parseInt(u32, count_res, 10)) |c| {
            count = c;
        } else |_| {}
    } else if (sh.runTrimBuf(io, "command -v dunstctl", &buf).len > 0) {
        var out_buf: [64]u8 = undefined;
        const paused_res = sh.runTrimBuf(io, "dunstctl is-paused", &out_buf);
        if (mem.eql(u8, paused_res, "true")) dnd_active = true;

        var count_buf: [64]u8 = undefined;
        const count_res = sh.runTrimBuf(io, "dunstctl count waiting", &count_buf);
        if (fmt.parseInt(u32, count_res, 10)) |c| {
            count = c;
        } else |_| {}
    } else if (sh.runTrimBuf(io, "command -v makoctl", &buf).len > 0) {
        var out_buf: [64]u8 = undefined;
        const mode_res = sh.runTrimBuf(io, "makoctl mode", &out_buf);
        if (mem.find(u8, mode_res, "do-not-disturb") != null) dnd_active = true;
    }

    this.renderState(dnd_active, count);
}

fn renderState(this: *DndModule, dnd_active: bool, count: u32) void {
    this.is_dnd = dnd_active;
    this.notification_count = count;

    if (dnd_active) {
        this.base.addCssClass("dnd-active");
        this.base.addCssClass("inhibited");
    } else {
        this.base.removeCssClass("dnd-active");
        this.base.removeCssClass("inhibited");
    }

    const icon_str: []const u8 = if (dnd_active)
        this.icon_dnd
    else if (count > 0)
        this.icon_normal
    else
        this.icon_none;

    this.replacer.clear();
    this.replacer.addKey("icon", icon_str) catch {};
    this.replacer.addKeyAny("count", count) catch {};
    this.replacer.addKey("status", if (dnd_active) "dnd" else "normal") catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "Notifications: {d} (DND: {s})", .{
            count,
            if (dnd_active) "Enabled" else "Disabled",
        }) catch "DND";
        this.base.setTooltip(tt);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *DndModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
