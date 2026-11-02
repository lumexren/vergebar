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
const fmt = std.fmt;
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;

pub const SystemdFailedModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    format_ok: []const u8,
    hide_on_ok: bool,
    interval_sec: u32,
    timer_id: u32 = 0,
    system_conn: ?*gtk.GDBusConnection = null,
    user_conn: ?*gtk.GDBusConnection = null,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*SystemdFailedModule {
        const self = try allocator.create(SystemdFailedModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "systemd-failed-units", settings);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "✗ {nr_failed}";
        const format_ok_str = settings.getString("format-ok") orelse "✓";
        const hide_ok = settings.getBool("hide-on-ok") orelse false;
        const interval = @as(u32, @intCast(settings.getInt("interval") orelse 5));

        var err: ?*anyopaque = null;
        const sys_conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.system), null, &err);
        err = null;
        const usr_conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.session), null, &err);

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, format_str),
            .format_ok = try allocator.dupe(u8, format_ok_str),
            .hide_on_ok = hide_ok,
            .interval_sec = interval,
            .system_conn = sys_conn,
            .user_conn = usr_conn,
        };

        self.update();
        self.timer_id = gtk.g_timeout_add_seconds(self.interval_sec, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *SystemdFailedModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        if (self.system_conn) |c| gtk.g_object_unref(c);
        if (self.user_conn) |c| gtk.g_object_unref(c);
        self.allocator.free(self.format);
        self.allocator.free(self.format_ok);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    fn countFailed(conn: ?*gtk.GDBusConnection) usize {
        const c = conn orelse return 0;
        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_connection_call_sync(
            c,
            "org.freedesktop.systemd1",
            "/org/freedesktop/systemd1",
            "org.freedesktop.systemd1.Manager",
            "ListUnitsByPatterns",
            gtk.g_variant_new("(asas)", gtk.g_variant_new_strv(null, 0), gtk.g_variant_new_strv(null, 0)),
            null,
            0,
            1000,
            null,
            &err,
        );
        if (res == null) {
            if (err) |e| gtk.g_error_free(e);
            return 0;
        }
        defer gtk.g_variant_unref(res);

        const outer = gtk.g_variant_get_child_value(res, 0);
        if (outer == null) return 0;
        defer gtk.g_variant_unref(outer);

        if (gtk.g_variant_is_container(outer) != 0) {
            const n = gtk.g_variant_n_children(outer);
            var failed: usize = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const item = gtk.g_variant_get_child_value(outer, i);
                if (item) |it| {
                    defer gtk.g_variant_unref(it);
                    const active_state = gtk.g_variant_get_child_value(it, 3);
                    if (active_state) |as_val| {
                        defer gtk.g_variant_unref(as_val);
                        if (gtk.g_variant_get_string(as_val, null)) |str_ptr| {
                            const s = mem.span(str_ptr);
                            if (mem.eql(u8, s, "failed")) failed += 1;
                        }
                    }
                }
            }
            return failed;
        }
        return 0;
    }

    pub fn update(self: *SystemdFailedModule) void {
        const n_sys = countFailed(self.system_conn);
        const n_usr = countFailed(self.user_conn);
        const total = n_sys + n_usr;

        if (self.hide_on_ok and total == 0) {
            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
            return;
        } else {
            if (self.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
        }

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKeyAny("nr_failed", @as(i64, @intCast(total))) catch {};
        replacer.addKeyAny("nr_failed_system", @as(i64, @intCast(n_sys))) catch {};
        replacer.addKeyAny("nr_failed_user", @as(i64, @intCast(n_usr))) catch {};

        const tmpl = if (total == 0) self.format_ok else self.format;
        const rendered = replacer.render(tmpl) catch tmpl;
        defer if (rendered.ptr != tmpl.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        if (total > 0) {
            self.base.addCssClass("failed");
            self.base.removeCssClass("ok");
            var tt_buf: [128]u8 = undefined;
            const tt = mem.print(&tt_buf, "Failed units: {d} (system: {d}, user: {d})", .{ total, n_sys, n_usr }) catch "Failed units";
            self.base.setTooltip(tt);
        } else {
            self.base.addCssClass("ok");
            self.base.removeCssClass("failed");
            self.base.setTooltip("All systemd units operational");
        }
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *SystemdFailedModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
