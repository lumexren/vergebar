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
const Io = std.Io;
const ArrayList = std.ArrayList;
const debug = std.debug;
const gtk = @import("gtk");
const ModuleSettings = @import("utils").Config.ModuleSettings;

const TrayModule = @This();

pub const MenuItemClickContext = @import("MenuItemClickContext.zig");
pub const TrayItem = @import("TrayItem.zig");
pub const WatcherItemWatch = @import("WatcherItemWatch.zig");

allocator: Allocator,
box: ?*gtk.GtkWidget,
icon_size: c_int,
spacing: c_int,
reverse_direction: bool,
show_passive: bool,
items: ArrayList(*TrayItem),
conn: ?*gtk.GDBusConnection = null,
sub_registered: c_uint = 0,
sub_unregistered: c_uint = 0,
watcher_owned_id: c_uint = 0,
watcher_object_id: c_uint = 0,
watcher_node_info: ?*anyopaque = null,
watcher_items: ArrayList([]const u8),
watcher_watches: ArrayList(*WatcherItemWatch),

pub fn create(io: Io, allocator: Allocator, name_hint: []const u8, settings: ModuleSettings) !*TrayModule {
    _ = io;
    _ = name_hint;
    const this = try allocator.create(TrayModule);
    errdefer allocator.destroy(this);

    const icon_size = @as(c_int, @intCast(settings.getInt("icon-size") orelse 16));
    const spacing = @as(c_int, @intCast(settings.getInt("spacing") orelse 4));
    const reverse = settings.getBool("reverse-direction") orelse false;
    const show_passive = settings.getBool("show-passive-items") orelse false;

    this.* = .{
        .allocator = allocator,
        .box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, spacing),
        .icon_size = icon_size,
        .spacing = spacing,
        .reverse_direction = reverse,
        .show_passive = show_passive,
        .items = .empty,
        .watcher_items = .empty,
        .watcher_watches = .empty,
    };

    if (this.box) |b| {
        gtk.gtk_widget_set_name(b, "tray");
        gtk.gtk_widget_add_css_class(b, "tray");
    }

    var err: ?*anyopaque = null;
    this.conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.session), null, &err);
    if (this.conn) |c| {
        const has_watcher = hasNameOwner(c, "org.kde.StatusNotifierWatcher");

        if (has_watcher) {
            const unique_name = gtk.g_dbus_connection_get_unique_name(c);
            if (unique_name) |un| {
                const host_call = gtk.g_dbus_connection_call_sync(
                    c,
                    "org.kde.StatusNotifierWatcher",
                    "/StatusNotifierWatcher",
                    "org.kde.StatusNotifierWatcher",
                    "RegisterStatusNotifierHost",
                    gtk.g_variant_new_parsed("(%s,)", un),
                    null,
                    0,
                    1000,
                    null,
                    &err,
                );
                if (host_call) |hc| {
                    gtk.g_variant_unref(hc);
                }
            }
        } else {
            this.setupInternalWatcher(c);
        }

        this.sub_registered = gtk.g_dbus_connection_signal_subscribe(
            c,
            "org.kde.StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "StatusNotifierItemRegistered",
            "/StatusNotifierWatcher",
            null,
            0,
            @ptrCast(&onItemRegistered),
            this,
            null,
        );

        this.sub_unregistered = gtk.g_dbus_connection_signal_subscribe(
            c,
            "org.kde.StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "StatusNotifierItemUnregistered",
            "/StatusNotifierWatcher",
            null,
            0,
            @ptrCast(&onItemUnregistered),
            this,
            null,
        );

        this.fetchInitialItems();
    }

    return this;
}

pub fn deinit(this: *TrayModule) void {
    if (this.conn) |c| {
        if (this.watcher_object_id != 0) {
            _ = gtk.g_dbus_connection_unregister_object(c, this.watcher_object_id);
            this.watcher_object_id = 0;
        }
        if (this.sub_registered != 0) {
            gtk.g_dbus_connection_signal_unsubscribe(c, this.sub_registered);
            this.sub_registered = 0;
        }
        if (this.sub_unregistered != 0) {
            gtk.g_dbus_connection_signal_unsubscribe(c, this.sub_unregistered);
            this.sub_unregistered = 0;
        }
    }

    if (this.watcher_owned_id != 0) {
        gtk.g_bus_unown_name(this.watcher_owned_id);
        this.watcher_owned_id = 0;
    }

    if (this.watcher_node_info) |info| {
        gtk.g_dbus_node_info_unref(info);
        this.watcher_node_info = null;
    }

    for (this.watcher_watches.items) |w| {
        if (w.watch_id != 0) gtk.g_bus_unwatch_name(w.watch_id);
        this.allocator.free(w.bus_name);
        this.allocator.free(w.full_id);
        this.allocator.destroy(w);
    }
    this.watcher_watches.deinit(this.allocator);

    for (this.watcher_items.items) |it| {
        this.allocator.free(it);
    }
    this.watcher_items.deinit(this.allocator);

    for (this.items.items) |item| {
        if (item.button) |btn| {
            if (this.box) |b| {
                gtk.gtk_box_remove(@ptrCast(b), btn);
            }
        }
        item.deinit();
    }
    this.items.deinit(this.allocator);
    this.allocator.destroy(this);
}

fn setupInternalWatcher(this: *TrayModule, conn: ?*gtk.GDBusConnection) void {
    const c = conn orelse return;
    var err: ?*anyopaque = null;

    this.watcher_node_info = gtk.g_dbus_node_info_new_for_xml(WATCHER_XML.ptr, &err);
    if (this.watcher_node_info) |info| {
        const iface = gtk.g_dbus_node_info_lookup_interface(info, "org.kde.StatusNotifierWatcher");
        if (iface != null) {
            this.watcher_object_id = gtk.g_dbus_connection_register_object(
                c,
                "/StatusNotifierWatcher",
                iface,
                &watcher_vtable,
                this,
                null,
                &err,
            );
            debug.print("Registered D-Bus object /StatusNotifierWatcher (id={d})\n", .{this.watcher_object_id});
        }
    }

    this.watcher_owned_id = gtk.g_bus_own_name_on_connection(
        c,
        "org.kde.StatusNotifierWatcher",
        0,
        null,
        null,
        this,
        null,
    );
    debug.print("Claimed org.kde.StatusNotifierWatcher as standalone tray host\n", .{});
}

pub fn registerItemFromWatcher(this: *TrayModule, bus_name: []const u8, obj_path: []const u8) void {
    const full_id = this.allocator.print("{s}{s}", .{ bus_name, obj_path }) catch return;
    defer this.allocator.free(full_id);

    for (this.watcher_items.items) |existing| {
        if (mem.eql(u8, existing, full_id)) return;
    }

    const full_id_dupe = this.allocator.dupe(u8, full_id) catch return;
    this.watcher_items.append(this.allocator, full_id_dupe) catch {
        this.allocator.free(full_id_dupe);
        return;
    };

    const bus_name_z = this.allocator.dupeSentinel(u8, bus_name, 0) catch return;
    const full_z = this.allocator.dupeSentinel(u8, full_id, 0) catch {
        this.allocator.free(bus_name_z);
        return;
    };

    const watch_ctx = this.allocator.create(WatcherItemWatch) catch {
        this.allocator.free(bus_name_z);
        this.allocator.free(full_z);
        return;
    };
    watch_ctx.* = .{
        .tray = this,
        .bus_name = bus_name_z,
        .full_id = full_z,
        .watch_id = 0,
    };

    if (this.conn) |c| {
        watch_ctx.watch_id = gtk.g_bus_watch_name_on_connection(
            c,
            bus_name_z.ptr,
            0,
            null,
            &onWatchedNameVanished,
            watch_ctx,
            null,
        );
        this.watcher_watches.append(this.allocator, watch_ctx) catch {};

        const sig_param = gtk.g_variant_new_parsed("(%s,)", full_z.ptr);
        _ = gtk.g_dbus_connection_emit_signal(
            c,
            null,
            "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "StatusNotifierItemRegistered",
            sig_param,
            null,
        );
    }

    this.addItem(full_id);
}

fn fetchInitialItems(this: *TrayModule) void {
    const c = this.conn orelse return;
    var err: ?*anyopaque = null;
    const res = gtk.g_dbus_connection_call_sync(
        c,
        "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher",
        "org.freedesktop.DBus.Properties",
        "Get",
        gtk.g_variant_new_parsed("('org.kde.StatusNotifierWatcher', 'RegisteredStatusNotifierItems')"),
        null,
        0,
        1000,
        null,
        &err,
    );
    if (res == null) {
        if (err) |e| gtk.g_error_free(e);
        return;
    }
    defer gtk.g_variant_unref(res);

    const outer = gtk.g_variant_get_child_value(res, 0);
    if (outer == null) return;
    defer gtk.g_variant_unref(outer);

    const inner = gtk.g_variant_get_child_value(outer, 0);
    if (inner == null) return;
    defer gtk.g_variant_unref(inner);

    const iter = gtk.g_variant_iter_new(inner);
    if (iter) |it| {
        defer gtk.g_variant_iter_free(it);
        while (gtk.g_variant_iter_next_value(it)) |val| {
            defer gtk.g_variant_unref(val);
            if (gtk.g_variant_get_string(val, null)) |s| {
                this.addItem(mem.span(s));
            }
        }
    }
}

pub fn addItem(this: *TrayModule, service_and_path: []const u8) void {
    if (service_and_path.len == 0) return;

    var service: []const u8 = service_and_path;
    var path: []const u8 = "/StatusNotifierItem";

    if (mem.findScalar(u8, service_and_path, '/')) |slash_idx| {
        service = service_and_path[0..slash_idx];
        path = service_and_path[slash_idx..];
    }

    for (this.items.items) |item| {
        if (mem.eql(u8, item.service, service) and mem.eql(u8, item.path, path)) {
            return;
        }
    }

    const service_z = this.allocator.dupeSentinel(u8, service, 0) catch return;
    errdefer this.allocator.free(service_z);
    const path_z = this.allocator.dupeSentinel(u8, path, 0) catch return;
    errdefer this.allocator.free(path_z);

    const c = this.conn orelse return;
    var err: ?*anyopaque = null;
    const proxy = gtk.g_dbus_proxy_new_sync(
        c,
        0,
        null,
        service_z.ptr,
        path_z.ptr,
        "org.kde.StatusNotifierItem",
        null,
        &err,
    );
    if (proxy == null) {
        if (err) |e| gtk.g_error_free(e);
        return;
    }

    const owner = gtk.g_dbus_proxy_get_name_owner(proxy);
    if (owner == null) {
        gtk.g_object_unref(proxy);
        return;
    }

    const item = this.allocator.create(TrayItem) catch {
        gtk.g_object_unref(proxy);
        return;
    };

    item.* = .{
        .allocator = this.allocator,
        .tray = this,
        .service = service_z,
        .path = path_z,
        .proxy = proxy,
        .conn = c,
    };

    const btn = gtk.gtk_button_new();
    gtk.gtk_button_set_has_frame(btn, 0);
    gtk.gtk_widget_add_css_class(btn, "tray-item");
    gtk.gtk_widget_add_css_class(btn, "item");
    gtk.gtk_widget_set_size_request(btn, this.icon_size, this.icon_size);
    gtk.gtk_widget_set_valign(btn, gtk.GTK_ALIGN_CENTER);
    gtk.gtk_widget_set_halign(btn, gtk.GTK_ALIGN_CENTER);

    const img = gtk.gtk_image_new();
    gtk.gtk_image_set_pixel_size(@ptrCast(img), this.icon_size);
    gtk.gtk_button_set_child(btn, img);

    item.button = btn;
    item.image = img;

    const gesture = gtk.gtk_gesture_click_new();
    if (gesture) |g| {
        gtk.gtk_gesture_single_set_button(@ptrCast(g), 0);
        _ = gtk.g_signal_connect_data(
            g,
            "pressed",
            @ptrCast(&onItemClicked),
            item,
            null,
            0,
        );
        gtk.gtk_widget_add_controller(btn, @ptrCast(g));
    }

    const scroll = gtk.gtk_event_controller_scroll_new(gtk.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    if (scroll) |s| {
        _ = gtk.g_signal_connect_data(
            s,
            "scroll",
            @ptrCast(&onItemScrolled),
            item,
            null,
            0,
        );
        gtk.gtk_widget_add_controller(btn, @ptrCast(s));
    }

    _ = gtk.g_signal_connect_data(
        proxy,
        "notify::g-name-owner",
        @ptrCast(&onItemNameOwnerChanged),
        item,
        null,
        0,
    );

    item.updateMenuPath();
    item.updateIcon();
    item.updateTitle();
    item.updateStatus();

    item.sig_icon = gtk.g_dbus_connection_signal_subscribe(
        c,
        service_z.ptr,
        "org.kde.StatusNotifierItem",
        "NewIcon",
        path_z.ptr,
        null,
        0,
        @ptrCast(&onItemNewIcon),
        item,
        null,
    );

    item.sig_attention_icon = gtk.g_dbus_connection_signal_subscribe(
        c,
        service_z.ptr,
        "org.kde.StatusNotifierItem",
        "NewAttentionIcon",
        path_z.ptr,
        null,
        0,
        @ptrCast(&onItemNewIcon),
        item,
        null,
    );

    item.sig_overlay_icon = gtk.g_dbus_connection_signal_subscribe(
        c,
        service_z.ptr,
        "org.kde.StatusNotifierItem",
        "NewOverlayIcon",
        path_z.ptr,
        null,
        0,
        @ptrCast(&onItemNewIcon),
        item,
        null,
    );

    item.sig_title = gtk.g_dbus_connection_signal_subscribe(
        c,
        service_z.ptr,
        "org.kde.StatusNotifierItem",
        "NewTitle",
        path_z.ptr,
        null,
        0,
        @ptrCast(&onItemNewTitle),
        item,
        null,
    );

    item.sig_status = gtk.g_dbus_connection_signal_subscribe(
        c,
        service_z.ptr,
        "org.kde.StatusNotifierItem",
        "NewStatus",
        path_z.ptr,
        null,
        0,
        @ptrCast(&onItemNewStatus),
        item,
        null,
    );

    item.sig_tooltip = gtk.g_dbus_connection_signal_subscribe(
        c,
        service_z.ptr,
        "org.kde.StatusNotifierItem",
        "NewToolTip",
        path_z.ptr,
        null,
        0,
        @ptrCast(&onItemNewTitle),
        item,
        null,
    );

    if (this.box) |b| {
        if (this.reverse_direction) {
            gtk.gtk_box_prepend(@ptrCast(b), btn);
        } else {
            gtk.gtk_box_append(@ptrCast(b), btn);
        }
    }

    this.items.append(this.allocator, item) catch {
        item.deinit();
        return;
    };
}

pub fn removeItem(this: *TrayModule, service_and_path: []const u8) void {
    var service = service_and_path;
    var path: []const u8 = "/StatusNotifierItem";
    if (mem.findScalar(u8, service_and_path, '/')) |slash_idx| {
        service = service_and_path[0..slash_idx];
        path = service_and_path[slash_idx..];
    }

    var i: usize = 0;
    while (i < this.items.items.len) {
        const item = this.items.items[i];
        if (mem.eql(u8, item.service, service) and (path.len == 0 or mem.eql(u8, item.path, path))) {
            if (item.button) |btn| {
                if (this.box) |b| {
                    gtk.gtk_box_remove(@ptrCast(b), btn);
                }
            }
            _ = this.items.swapRemove(i);
            item.deinit();
            return;
        } else {
            i += 1;
        }
    }
}

const WATCHER_XML: [:0]const u8 =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.kde.StatusNotifierWatcher">
    \\    <method name="RegisterStatusNotifierItem">
    \\      <arg name="service" type="s" direction="in"/>
    \\    </method>
    \\    <method name="RegisterStatusNotifierHost">
    \\      <arg name="service" type="s" direction="in"/>
    \\    </method>
    \\    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    \\    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    \\    <property name="ProtocolVersion" type="i" access="read"/>
    \\    <signal name="StatusNotifierItemRegistered">
    \\      <arg type="s" direction="out" name="service"/>
    \\    </signal>
    \\    <signal name="StatusNotifierItemUnregistered">
    \\      <arg type="s" direction="out" name="service"/>
    \\    </signal>
    \\    <signal name="StatusNotifierHostRegistered"/>
    \\    <signal name="StatusNotifierHostUnregistered"/>
    \\  </interface>
    \\</node>
;

const watcher_vtable: gtk.GDBusInterfaceVTable = .{
    .method_call = &onWatcherMethodCall,
    .get_property = &onWatcherGetProperty,
    .set_property = null,
    .padding = [_]gtk.gpointer{ null, null, null, null, null, null, null, null },
};

fn onWatcherMethodCall(
    conn: ?*gtk.GDBusConnection,
    sender: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    parameters: ?*gtk.GVariant,
    invocation: ?*anyopaque,
    user_data: gtk.gpointer,
) callconv(.c) void {
    _ = conn;
    _ = object_path;
    _ = interface_name;
    const this: *TrayModule = @ptrCast(@alignCast(user_data orelse return));
    const m_name = mem.span(method_name);

    if (mem.eql(u8, m_name, "RegisterStatusNotifierItem")) {
        if (parameters) |p| {
            const child = gtk.g_variant_get_child_value(p, 0);
            if (child) |c| {
                defer gtk.g_variant_unref(c);
                if (gtk.g_variant_get_string(c, null)) |raw_service| {
                    const raw_s = mem.span(raw_service);
                    var bus_name_buf: [256]u8 = undefined;
                    var obj_path_buf: [256]u8 = undefined;
                    var bus_name: []const u8 = "";
                    var obj_path: []const u8 = "";

                    if (raw_s.len > 0 and raw_s[0] == '/') {
                        const s_sender = mem.span(sender);
                        const b_len = @min(s_sender.len, bus_name_buf.len - 1);
                        @memcpy(bus_name_buf[0..b_len], s_sender[0..b_len]);
                        bus_name_buf[b_len] = 0;
                        bus_name = bus_name_buf[0..b_len];

                        const o_len = @min(raw_s.len, obj_path_buf.len - 1);
                        @memcpy(obj_path_buf[0..o_len], raw_s[0..o_len]);
                        obj_path_buf[o_len] = 0;
                        obj_path = obj_path_buf[0..o_len];
                    } else if (mem.findScalar(u8, raw_s, '/')) |slash| {
                        bus_name = raw_s[0..slash];
                        obj_path = raw_s[slash..];
                    } else {
                        bus_name = raw_s;
                        obj_path = "/StatusNotifierItem";
                    }

                    this.registerItemFromWatcher(bus_name, obj_path);
                }
            }
        }
        gtk.g_dbus_method_invocation_return_value(invocation, null);
    } else if (mem.eql(u8, m_name, "RegisterStatusNotifierHost")) {
        if (this.conn) |c| {
            _ = gtk.g_dbus_connection_emit_signal(
                c,
                null,
                "/StatusNotifierWatcher",
                "org.kde.StatusNotifierWatcher",
                "StatusNotifierHostRegistered",
                null,
                null,
            );
        }
        gtk.g_dbus_method_invocation_return_value(invocation, null);
    }
}

fn onWatcherGetProperty(
    conn: ?*gtk.GDBusConnection,
    sender: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    property_name: [*:0]const u8,
    err: ?*?*anyopaque,
    user_data: gtk.gpointer,
) callconv(.c) ?*gtk.GVariant {
    _ = conn;
    _ = sender;
    _ = object_path;
    _ = interface_name;
    _ = err;
    const this: *TrayModule = @ptrCast(@alignCast(user_data orelse return null));
    const p_name = mem.span(property_name);

    if (mem.eql(u8, p_name, "RegisteredStatusNotifierItems")) {
        var str_ptrs = this.allocator.alloc(?[*:0]const u8, this.watcher_items.items.len + 1) catch return null;
        defer this.allocator.free(str_ptrs);

        for (this.watcher_items.items, 0..) |it, idx| {
            const z = this.allocator.dupeSentinel(u8, it, 0) catch return null;
            str_ptrs[idx] = z.ptr;
        }
        defer {
            for (0..this.watcher_items.items.len) |idx| {
                if (str_ptrs[idx]) |ptr| this.allocator.free(mem.span(ptr));
            }
        }
        str_ptrs[this.watcher_items.items.len] = null;
        return gtk.g_variant_new_strv(@ptrCast(str_ptrs.ptr), @intCast(this.watcher_items.items.len));
    } else if (mem.eql(u8, p_name, "IsStatusNotifierHostRegistered")) {
        return gtk.g_variant_new_boolean(1);
    } else if (mem.eql(u8, p_name, "ProtocolVersion")) {
        return gtk.g_variant_new_int32(0);
    }
    return null;
}

fn onWatchedNameVanished(
    conn: ?*gtk.GDBusConnection,
    name: [*:0]const u8,
    user_data: gtk.gpointer,
) callconv(.c) void {
    _ = conn;
    _ = name;
    const ctx: *WatcherItemWatch = @ptrCast(@alignCast(user_data orelse return));
    const tray = ctx.tray;

    if (tray.conn) |c| {
        const sig_param = gtk.g_variant_new_parsed("(%s,)", ctx.full_id.ptr);
        _ = gtk.g_dbus_connection_emit_signal(
            c,
            null,
            "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "StatusNotifierItemUnregistered",
            sig_param,
            null,
        );
    }

    tray.removeItem(ctx.full_id);

    var i: usize = 0;
    while (i < tray.watcher_items.items.len) {
        if (mem.eql(u8, tray.watcher_items.items[i], ctx.full_id)) {
            const removed = tray.watcher_items.swapRemove(i);
            tray.allocator.free(removed);
        } else {
            i += 1;
        }
    }

    i = 0;
    while (i < tray.watcher_watches.items.len) {
        if (tray.watcher_watches.items[i] == ctx) {
            _ = tray.watcher_watches.swapRemove(i);
            break;
        } else {
            i += 1;
        }
    }

    if (ctx.watch_id != 0) gtk.g_bus_unwatch_name(ctx.watch_id);
    tray.allocator.free(ctx.bus_name);
    tray.allocator.free(ctx.full_id);
    tray.allocator.destroy(ctx);
}

fn onItemNameOwnerChanged(
    proxy: ?*gtk.GDBusProxy,
    pspec: ?*anyopaque,
    user_data: gtk.gpointer,
) callconv(.c) void {
    _ = pspec;
    const item: *TrayItem = @ptrCast(@alignCast(user_data orelse return));
    const owner = gtk.g_dbus_proxy_get_name_owner(proxy);
    if (owner == null) {
        item.tray.removeItem(item.service);
    }
}

fn onItemClicked(
    gesture: ?*gtk.GtkGestureClick,
    n_press: c_int,
    x: f64,
    y: f64,
    user_data: gtk.gpointer,
) callconv(.c) void {
    _ = n_press;
    const item: *TrayItem = @ptrCast(@alignCast(user_data orelse return));
    const p = item.proxy orelse return;
    const btn = gtk.gtk_gesture_single_get_current_button(@ptrCast(gesture));

    var root_x: c_int = 0;
    var root_y: c_int = 0;
    if (item.button) |btn_w| {
        const root_widget = gtk.gtk_widget_get_root(btn_w);
        if (root_widget != null) {
            const pt: gtk.graphene_point_t = .{ .x = @floatCast(x), .y = @floatCast(y) };
            var out_pt: gtk.graphene_point_t = undefined;
            if (gtk.gtk_widget_compute_point(btn_w, @ptrCast(root_widget), &pt, &out_pt) != 0) {
                root_x = @as(c_int, @intFromFloat(out_pt.x));
                root_y = @as(c_int, @intFromFloat(out_pt.y));
            }
        }
    }

    var is_menu = false;
    const is_menu_prop = gtk.g_dbus_proxy_get_cached_property(p, "ItemIsMenu");
    if (is_menu_prop) |mp| {
        defer gtk.g_variant_unref(mp);
        is_menu = gtk.g_variant_get_boolean(mp) != 0;
    }

    if (btn == 3 or ((btn == 1) and is_menu)) {
        if (item.menu_path != null) {
            item.openMenu();
            return;
        }

        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_proxy_call_sync(
            p,
            "ContextMenu",
            gtk.g_variant_new_parsed("(%i, %i)", root_x, root_y),
            0,
            1000,
            null,
            &err,
        );
        if (res != null) {
            gtk.g_variant_unref(res);
        } else {
            if (err) |e| {
                gtk.g_error_free(e);
                err = null;
            }
            const res2 = gtk.g_dbus_proxy_call_sync(
                p,
                "Activate",
                gtk.g_variant_new_parsed("(%i, %i)", root_x, root_y),
                0,
                1000,
                null,
                &err,
            );
            if (res2) |r2| {
                gtk.g_variant_unref(r2);
            } else if (err) |e| {
                gtk.g_error_free(e);
            }
        }
    } else if (btn == 1) {
        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_proxy_call_sync(
            p,
            "Activate",
            gtk.g_variant_new_parsed("(%i, %i)", root_x, root_y),
            0,
            1000,
            null,
            &err,
        );
        if (res != null) {
            gtk.g_variant_unref(res);
        } else {
            if (err) |e| {
                gtk.g_error_free(e);
                err = null;
            }
            if (item.menu_path != null) {
                item.openMenu();
            } else {
                const res2 = gtk.g_dbus_proxy_call_sync(
                    p,
                    "SecondaryActivate",
                    gtk.g_variant_new_parsed("(%i, %i)", root_x, root_y),
                    0,
                    1000,
                    null,
                    &err,
                );
                if (res2) |r2| {
                    gtk.g_variant_unref(r2);
                } else if (err) |e| {
                    gtk.g_error_free(e);
                }
            }
        }
    } else if (btn == 2) {
        var err: ?*anyopaque = null;
        const res = gtk.g_dbus_proxy_call_sync(
            p,
            "SecondaryActivate",
            gtk.g_variant_new_parsed("(%i, %i)", root_x, root_y),
            0,
            1000,
            null,
            &err,
        );
        if (res) |r| {
            gtk.g_variant_unref(r);
        } else if (err) |e| {
            gtk.g_error_free(e);
        }
    }
}

fn onItemScrolled(
    controller: ?*gtk.GtkEventControllerScroll,
    dx: f64,
    dy: f64,
    user_data: gtk.gpointer,
) callconv(.c) gtk.gboolean {
    _ = controller;
    const item: *TrayItem = @ptrCast(@alignCast(user_data orelse return 0));
    const p = item.proxy orelse return 0;

    var err: ?*anyopaque = null;
    if (dy != 0) {
        const delta: c_int = if (dy > 0) 1 else -1;
        const res = gtk.g_dbus_proxy_call_sync(
            p,
            "Scroll",
            gtk.g_variant_new_parsed("(%i, 'vertical')", delta),
            0,
            1000,
            null,
            &err,
        );
        if (res) |r| gtk.g_variant_unref(r) else if (err) |e| gtk.g_error_free(e);
        return 1;
    }
    if (dx != 0) {
        const delta: c_int = if (dx > 0) 1 else -1;
        const res = gtk.g_dbus_proxy_call_sync(
            p,
            "Scroll",
            gtk.g_variant_new_parsed("(%i, 'horizontal')", delta),
            0,
            1000,
            null,
            &err,
        );
        if (res) |r| gtk.g_variant_unref(r) else if (err) |e| gtk.g_error_free(e);
        return 1;
    }
    return 0;
}

fn onItemNewIcon(
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
    const item: *TrayItem = @ptrCast(@alignCast(user_data orelse return));
    item.updateIcon();
}

fn onItemNewTitle(
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
    const item: *TrayItem = @ptrCast(@alignCast(user_data orelse return));
    item.updateMenuPath();
    item.updateTitle();
}

fn onItemNewStatus(
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
    const item: *TrayItem = @ptrCast(@alignCast(user_data orelse return));
    item.updateStatus();
}

fn onItemRegistered(
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
    const this: *TrayModule = @ptrCast(@alignCast(user_data orelse return));
    if (parameters) |p| {
        const val = gtk.g_variant_get_child_value(p, 0);
        if (val) |v| {
            defer gtk.g_variant_unref(v);
            if (gtk.g_variant_get_string(v, null)) |str| {
                this.addItem(mem.span(str));
            }
        }
    }
}

fn onItemUnregistered(
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
    const this: *TrayModule = @ptrCast(@alignCast(user_data orelse return));
    if (parameters) |p| {
        const val = gtk.g_variant_get_child_value(p, 0);
        if (val) |v| {
            defer gtk.g_variant_unref(v);
            if (gtk.g_variant_get_string(v, null)) |str| {
                this.removeItem(mem.span(str));
            }
        }
    }
}

fn hasNameOwner(conn: ?*gtk.GDBusConnection, name: [*:0]const u8) bool {
    var err: ?*anyopaque = null;
    const res = gtk.g_dbus_connection_call_sync(
        conn,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "GetNameOwner",
        gtk.g_variant_new_parsed("(%s,)", name),
        null,
        0,
        500,
        null,
        &err,
    );
    if (res) |r| {
        gtk.g_variant_unref(r);
        return true;
    }
    if (err) |e| gtk.g_error_free(e);
    return false;
}
