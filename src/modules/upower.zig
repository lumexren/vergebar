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

pub const UPowerModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    dbus_conn: ?*gtk.GDBusConnection = null,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*UPowerModule {
        const self = try allocator.create(UPowerModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "upower", settings);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "{percentage}%";

        var err: ?*anyopaque = null;
        const conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.system), null, &err);

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, format_str),
            .dbus_conn = conn,
        };

        self.update();
        self.timer_id = gtk.g_timeout_add_seconds(10, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *UPowerModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *UPowerModule) void {
        const c = self.dbus_conn orelse return;
        var err: ?*anyopaque = null;

        const res = gtk.g_dbus_connection_call_sync(
            c,
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower/devices/DisplayDevice",
            "org.freedesktop.DBus.Properties",
            "GetAll",
            gtk.g_variant_new_parsed("('org.freedesktop.UPower.Device',)"),
            null,
            0,
            1000,
            null,
            &err,
        );

        var percentage: f64 = 100.0;
        if (res) |r| {
            defer gtk.g_variant_unref(r);
            const child = gtk.g_variant_get_child_value(r, 0);
            if (child) |ch| {
                defer gtk.g_variant_unref(ch);
                const iter = gtk.g_variant_iter_new(ch);
                if (iter) |it| {
                    defer gtk.g_variant_iter_free(it);
                    while (gtk.g_variant_iter_next_value(it)) |entry| {
                        defer gtk.g_variant_unref(entry);
                        const k_val = gtk.g_variant_get_child_value(entry, 0);
                        if (k_val) |kv| {
                            defer gtk.g_variant_unref(kv);
                            if (gtk.g_variant_get_string(kv, null)) |key_ptr| {
                                if (mem.eql(u8, mem.span(key_ptr), "Percentage")) {
                                    const v_box = gtk.g_variant_get_child_value(entry, 1);
                                    if (v_box) |vb| {
                                        defer gtk.g_variant_unref(vb);
                                        const v_actual = gtk.g_variant_get_child_value(vb, 0);
                                        if (v_actual) |va| {
                                            defer gtk.g_variant_unref(va);
                                            percentage = gtk.g_variant_get_double(va);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKeyAny("percentage", @as(i64, @intFromFloat(percentage))) catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "UPower Display Device: {d:.0}%", .{percentage}) catch "UPower";
        self.base.setTooltip(tt);
    }
};

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *UPowerModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
