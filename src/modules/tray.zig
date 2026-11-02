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
const ArrayList = std.ArrayList;
const debug = std.debug;
const gtk = @import("gtk");
const ModuleSettings = @import("utils").Config.ModuleSettings;

pub const MenuItemClickContext = struct {
    tray: *TrayModule,
    service: [:0]const u8,
    menu_path: [:0]const u8,
    popover: ?*gtk.GtkWidget,
    id: i32,
};

pub const TrayItem = struct {
    allocator: Allocator,
    tray: *TrayModule,
    service: [:0]const u8,
    path: [:0]const u8,
    menu_path: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,
    icon_name: ?[:0]const u8 = null,
    status: ?[:0]const u8 = null,
    button: ?*gtk.GtkWidget = null,
    image: ?*gtk.GtkWidget = null,
    popover: ?*gtk.GtkWidget = null,
    proxy: ?*gtk.GDBusProxy = null,
    conn: ?*gtk.GDBusConnection = null,
    sig_icon: c_uint = 0,
    sig_attention_icon: c_uint = 0,
    sig_overlay_icon: c_uint = 0,
    sig_title: c_uint = 0,
    sig_status: c_uint = 0,
    sig_tooltip: c_uint = 0,

    pub fn deinit(self: *TrayItem) void {
        if (self.popover) |pop| {
            gtk.gtk_widget_unparent(pop);
            self.popover = null;
        }

        if (self.conn) |c| {
            if (self.sig_icon != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sig_icon);
            if (self.sig_attention_icon != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sig_attention_icon);
            if (self.sig_overlay_icon != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sig_overlay_icon);
            if (self.sig_title != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sig_title);
            if (self.sig_status != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sig_status);
            if (self.sig_tooltip != 0) gtk.g_dbus_connection_signal_unsubscribe(c, self.sig_tooltip);
            self.sig_icon = 0;
            self.sig_attention_icon = 0;
            self.sig_overlay_icon = 0;
            self.sig_title = 0;
            self.sig_status = 0;
            self.sig_tooltip = 0;
        }

        if (self.proxy) |p| {
            gtk.g_object_unref(p);
            self.proxy = null;
        }

        if (self.menu_path) |mp| self.allocator.free(mp);
        if (self.title) |t| self.allocator.free(t);
        if (self.icon_name) |i| self.allocator.free(i);
        if (self.status) |s| self.allocator.free(s);
        self.allocator.free(self.service);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn updateMenuPath(self: *TrayItem) void {
        const p = self.proxy orelse return;
        const menu_prop = gtk.g_dbus_proxy_get_cached_property(p, "Menu");
        if (menu_prop) |mp| {
            defer gtk.g_variant_unref(mp);
            if (gtk.g_variant_get_string(mp, null)) |path_ptr| {
                const path_str = mem.span(path_ptr);
                if (path_str.len > 0) {
                    if (self.menu_path) |old| self.allocator.free(old);
                    self.menu_path = self.allocator.dupeSentinel(u8, path_str, 0) catch null;
                }
            }
        }
    }

    pub fn updateIcon(self: *TrayItem) void {
        const p = self.proxy orelse return;

        const theme_path_prop = gtk.g_dbus_proxy_get_cached_property(p, "IconThemePath");
        if (theme_path_prop) |tp| {
            defer gtk.g_variant_unref(tp);
            if (gtk.g_variant_get_string(tp, null)) |path_ptr| {
                const p_slice = mem.span(path_ptr);
                if (p_slice.len > 0) {
                    const display = gtk.gdk_display_get_default();
                    if (display) |d| {
                        const theme = gtk.gtk_icon_theme_get_for_display(d);
                        if (theme) |t| {
                            gtk.gtk_icon_theme_add_search_path(t, path_ptr);
                        }
                    }
                }
            }
        }

        const icon_prop = gtk.g_dbus_proxy_get_cached_property(p, "IconName");
        if (icon_prop) |ip| {
            defer gtk.g_variant_unref(ip);
            if (gtk.g_variant_get_string(ip, null)) |name_ptr| {
                const name = mem.span(name_ptr);
                if (name.len > 0) {
                    if (self.icon_name) |old| self.allocator.free(old);
                    self.icon_name = self.allocator.dupeSentinel(u8, name, 0) catch null;
                    if (self.image) |img| {
                        gtk.gtk_image_set_from_icon_name(@ptrCast(img), name_ptr);
                    }
                    return;
                }
            }
        }

        const attn_prop = gtk.g_dbus_proxy_get_cached_property(p, "AttentionIconName");
        if (attn_prop) |ap| {
            defer gtk.g_variant_unref(ap);
            if (gtk.g_variant_get_string(ap, null)) |name_ptr| {
                const name = mem.span(name_ptr);
                if (name.len > 0) {
                    if (self.image) |img| {
                        gtk.gtk_image_set_from_icon_name(@ptrCast(img), name_ptr);
                    }
                    return;
                }
            }
        }

        const pixmap_prop = gtk.g_dbus_proxy_get_cached_property(p, "IconPixmap");
        if (pixmap_prop) |px| {
            defer gtk.g_variant_unref(px);
            if (self.tryLoadPixmap(px)) {
                return;
            }
        }

        const attn_pix = gtk.g_dbus_proxy_get_cached_property(p, "AttentionIconPixmap");
        if (attn_pix) |apx| {
            defer gtk.g_variant_unref(apx);
            if (self.tryLoadPixmap(apx)) {
                return;
            }
        }

        if (self.image) |img| {
            gtk.gtk_image_set_from_icon_name(@ptrCast(img), "application-x-executable");
        }
    }

    fn tryLoadPixmap(self: *TrayItem, pixmap_val: ?*gtk.GVariant) bool {
        const val = pixmap_val orelse return false;
        const iter = gtk.g_variant_iter_new(val) orelse return false;
        defer gtk.g_variant_iter_free(iter);

        var best_width: i32 = 0;
        var best_height: i32 = 0;
        var best_data: ?[]const u8 = null;
        var best_item: ?*gtk.GVariant = null;

        while (gtk.g_variant_iter_next_value(iter)) |elem| {
            const w_val = gtk.g_variant_get_child_value(elem, 0);
            const h_val = gtk.g_variant_get_child_value(elem, 1);
            const bytes_val = gtk.g_variant_get_child_value(elem, 2);

            if (w_val != null and h_val != null and bytes_val != null) {
                const w = gtk.g_variant_get_int32(w_val);
                const h = gtk.g_variant_get_int32(h_val);

                const bytes_len = gtk.g_variant_get_size(bytes_val);
                const raw_data: ?[*]const u8 = @ptrCast(gtk.g_variant_get_data(bytes_val));

                if (w > 0 and h > 0 and raw_data != null and bytes_len >= @as(usize, @intCast(w * h * 4))) {
                    if (best_data == null or @abs(w - self.tray.icon_size) < @abs(best_width - self.tray.icon_size)) {
                        if (best_item) |bi| gtk.g_variant_unref(bi);
                        best_width = w;
                        best_height = h;
                        best_data = raw_data.?[0..bytes_len];
                        best_item = elem;
                        gtk.g_variant_unref(w_val);
                        gtk.g_variant_unref(h_val);
                        gtk.g_variant_unref(bytes_val);
                        continue;
                    }
                }
            }

            if (w_val) |v| gtk.g_variant_unref(v);
            if (h_val) |v| gtk.g_variant_unref(v);
            if (bytes_val) |v| gtk.g_variant_unref(v);
            gtk.g_variant_unref(elem);
        }

        if (best_data) |data| {
            defer if (best_item) |bi| gtk.g_variant_unref(bi);
            const gbytes = gtk.g_bytes_new(data.ptr, data.len);
            if (gbytes) |gb| {
                defer gtk.g_bytes_unref(gb);
                const texture = gtk.gdk_memory_texture_new(best_width, best_height, 4, gb, @intCast(best_width * 4));
                if (texture) |tex| {
                    defer gtk.g_object_unref(tex);
                    if (self.image) |img| {
                        gtk.gtk_image_set_from_paintable(@ptrCast(img), tex);
                        return true;
                    }
                }
            }
        }

        return false;
    }

    pub fn updateTitle(self: *TrayItem) void {
        const p = self.proxy orelse return;
        var found_text: ?[*:0]const u8 = null;

        const title_prop = gtk.g_dbus_proxy_get_cached_property(p, "Title");
        if (title_prop) |tp| {
            defer gtk.g_variant_unref(tp);
            if (gtk.g_variant_get_string(tp, null)) |t| {
                if (mem.span(t).len > 0) found_text = t;
            }
        }

        if (found_text == null) {
            const id_prop = gtk.g_dbus_proxy_get_cached_property(p, "Id");
            if (id_prop) |ip| {
                defer gtk.g_variant_unref(ip);
                if (gtk.g_variant_get_string(ip, null)) |id_str| {
                    if (mem.span(id_str).len > 0) found_text = id_str;
                }
            }
        }

        if (found_text == null) {
            const tt_prop = gtk.g_dbus_proxy_get_cached_property(p, "ToolTip");
            if (tt_prop) |tt| {
                defer gtk.g_variant_unref(tt);
                const title_child = gtk.g_variant_get_child_value(tt, 2);
                if (title_child) |tc| {
                    defer gtk.g_variant_unref(tc);
                    if (gtk.g_variant_get_string(tc, null)) |tt_title| {
                        if (mem.span(tt_title).len > 0) found_text = tt_title;
                    }
                }
                if (found_text == null) {
                    const desc_child = gtk.g_variant_get_child_value(tt, 3);
                    if (desc_child) |dc| {
                        defer gtk.g_variant_unref(dc);
                        if (gtk.g_variant_get_string(dc, null)) |tt_desc| {
                            if (mem.span(tt_desc).len > 0) found_text = tt_desc;
                        }
                    }
                }
            }
        }

        if (found_text) |t| {
            if (self.button) |btn| {
                gtk.gtk_widget_set_tooltip_text(btn, t);
            }
        }
    }

    pub fn updateStatus(self: *TrayItem) void {
        const p = self.proxy orelse return;
        const status_prop = gtk.g_dbus_proxy_get_cached_property(p, "Status");
        if (status_prop) |sp| {
            defer gtk.g_variant_unref(sp);
            if (gtk.g_variant_get_string(sp, null)) |st| {
                const st_slice = mem.span(st);
                if (self.button) |btn| {
                    if (mem.eql(u8, st_slice, "Passive")) {
                        gtk.gtk_widget_add_css_class(btn, "passive");
                        gtk.gtk_widget_remove_css_class(btn, "active");
                        gtk.gtk_widget_remove_css_class(btn, "needs-attention");
                        gtk.gtk_widget_set_visible(btn, if (self.tray.show_passive) 1 else 0);
                    } else if (mem.eql(u8, st_slice, "NeedsAttention")) {
                        gtk.gtk_widget_add_css_class(btn, "needs-attention");
                        gtk.gtk_widget_remove_css_class(btn, "passive");
                        gtk.gtk_widget_remove_css_class(btn, "active");
                        gtk.gtk_widget_set_visible(btn, 1);
                    } else {
                        gtk.gtk_widget_add_css_class(btn, "active");
                        gtk.gtk_widget_remove_css_class(btn, "passive");
                        gtk.gtk_widget_remove_css_class(btn, "needs-attention");
                        gtk.gtk_widget_set_visible(btn, 1);
                    }
                }
            }
        }
    }

    pub fn openMenu(self: *TrayItem) void {
        const mp = self.menu_path orelse return;
        const c = self.conn orelse return;
        const btn_widget = self.button orelse return;

        var err: ?*anyopaque = null;
        const about_res = gtk.g_dbus_connection_call_sync(
            c,
            self.service.ptr,
            mp.ptr,
            "com.canonical.dbusmenu",
            "AboutToShow",
            gtk.g_variant_new_parsed("(0,)"),
            null,
            0,
            500,
            null,
            &err,
        );
        if (about_res) |ar| gtk.g_variant_unref(ar) else if (err) |e| {
            gtk.g_error_free(e);
            err = null;
        }

        const layout_res = gtk.g_dbus_connection_call_sync(
            c,
            self.service.ptr,
            mp.ptr,
            "com.canonical.dbusmenu",
            "GetLayout",
            gtk.g_variant_new_parsed("(0, 1, @as [])"),
            null,
            0,
            1000,
            null,
            &err,
        );
        if (layout_res == null) {
            if (err) |e| gtk.g_error_free(e);
            return;
        }
        defer gtk.g_variant_unref(layout_res);

        const root_node = gtk.g_variant_get_child_value(layout_res, 1);
        if (root_node == null) return;
        defer gtk.g_variant_unref(root_node);

        const children_arr = gtk.g_variant_get_child_value(root_node, 2);
        if (children_arr == null) return;
        defer gtk.g_variant_unref(children_arr);

        const n_children = gtk.g_variant_n_children(children_arr);
        if (n_children == 0) return;

        if (self.popover) |old_pop| {
            gtk.gtk_widget_unparent(old_pop);
            self.popover = null;
        }

        const pop = gtk.gtk_popover_new();
        if (pop == null) return;
        gtk.gtk_widget_set_parent(pop, btn_widget);
        self.popover = pop;

        _ = gtk.g_signal_connect_data(
            pop,
            "closed",
            @ptrCast(&onPopoverClosed),
            self,
            null,
            0,
        );

        const menu_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
        gtk.gtk_widget_add_css_class(menu_box, "tray-menu");

        var idx: usize = 0;
        while (idx < n_children) : (idx += 1) {
            const child_val = gtk.g_variant_get_child_value(children_arr, idx);
            if (child_val == null) continue;
            defer gtk.g_variant_unref(child_val);

            const item_tuple = gtk.g_variant_get_variant(child_val);
            if (item_tuple == null) continue;
            defer gtk.g_variant_unref(item_tuple);

            const id_val = gtk.g_variant_get_child_value(item_tuple, 0);
            const props_val = gtk.g_variant_get_child_value(item_tuple, 1);
            defer if (id_val) |iv| gtk.g_variant_unref(iv);
            defer if (props_val) |pv| gtk.g_variant_unref(pv);

            if (id_val == null or props_val == null) continue;
            const item_id = gtk.g_variant_get_int32(id_val);

            const vis_val = gtk.g_variant_lookup_value(props_val, "visible", null);
            if (vis_val) |vv| {
                defer gtk.g_variant_unref(vv);
                if (gtk.g_variant_get_boolean(vv) == 0) continue;
            }

            var is_separator = false;
            const type_val = gtk.g_variant_lookup_value(props_val, "type", null);
            if (type_val) |tv| {
                defer gtk.g_variant_unref(tv);
                if (gtk.g_variant_get_string(tv, null)) |t_str| {
                    if (mem.eql(u8, mem.span(t_str), "separator")) {
                        is_separator = true;
                    }
                }
            }

            if (is_separator) {
                const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
                if (sep) |s| {
                    gtk.gtk_widget_add_css_class(s, "menu-separator");
                    gtk.gtk_box_append(@ptrCast(menu_box), s);
                }
                continue;
            }

            var item_label: ?[:0]const u8 = null;
            const label_val = gtk.g_variant_lookup_value(props_val, "label", null);
            if (label_val) |lv| {
                defer gtk.g_variant_unref(lv);
                if (gtk.g_variant_get_string(lv, null)) |lbl_ptr| {
                    item_label = mem.span(lbl_ptr);
                }
            }

            const raw_label = item_label orelse "";
            if (raw_label.len == 0) continue;

            var is_enabled = true;
            const en_val = gtk.g_variant_lookup_value(props_val, "enabled", null);
            if (en_val) |ev| {
                defer gtk.g_variant_unref(ev);
                is_enabled = gtk.g_variant_get_boolean(ev) != 0;
            }

            var icon_name: ?[*:0]const u8 = null;
            const ic_val = gtk.g_variant_lookup_value(props_val, "icon-name", null);
            if (ic_val) |iv| {
                defer gtk.g_variant_unref(iv);
                if (gtk.g_variant_get_string(iv, null)) |ic_ptr| {
                    if (mem.span(ic_ptr).len > 0) icon_name = ic_ptr;
                }
            }

            const item_btn = gtk.gtk_button_new();
            gtk.gtk_button_set_has_frame(item_btn, 0);
            gtk.gtk_widget_add_css_class(item_btn, "menu-item");
            if (!is_enabled) {
                gtk.gtk_widget_set_sensitive(item_btn, 0);
            }

            const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 6);
            if (icon_name) |ic| {
                const img = gtk.gtk_image_new_from_icon_name(ic);
                gtk.gtk_image_set_pixel_size(@ptrCast(img), 14);
                gtk.gtk_box_append(@ptrCast(row), img);
            }

            var clean_buf: [256]u8 = undefined;
            var c_idx: usize = 0;
            for (raw_label) |ch| {
                if (ch != '_' and c_idx < clean_buf.len - 1) {
                    clean_buf[c_idx] = ch;
                    c_idx += 1;
                }
            }
            clean_buf[c_idx] = 0;

            const lbl = gtk.gtk_label_new(@ptrCast(&clean_buf));
            gtk.gtk_widget_set_halign(lbl, gtk.GTK_ALIGN_START);
            gtk.gtk_box_append(@ptrCast(row), lbl);
            gtk.gtk_button_set_child(item_btn, row);

            const click_ctx = self.allocator.create(MenuItemClickContext) catch continue;
            click_ctx.* = .{
                .tray = self.tray,
                .service = self.allocator.dupeSentinel(u8, self.service, 0) catch {
                    self.allocator.destroy(click_ctx);
                    continue;
                },
                .menu_path = self.allocator.dupeSentinel(u8, mp, 0) catch {
                    self.allocator.free(click_ctx.service);
                    self.allocator.destroy(click_ctx);
                    continue;
                },
                .popover = pop,
                .id = item_id,
            };

            _ = gtk.g_signal_connect_data(
                item_btn,
                "clicked",
                @ptrCast(&onMenuItemClicked),
                click_ctx,
                @ptrCast(&onMenuItemContextFree),
                0,
            );

            gtk.gtk_box_append(@ptrCast(menu_box), item_btn);
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), menu_box);
        gtk.gtk_popover_popup(@ptrCast(pop));
    }
};

fn onPopoverClosed(popover: ?*gtk.GtkPopover, user_data: gtk.gpointer) callconv(.c) void {
    _ = popover;
    const item: *TrayItem = @ptrCast(@alignCast(user_data orelse return));
    if (item.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        item.popover = null;
    }
}

fn onMenuItemClicked(btn: ?*gtk.GtkButton, user_data: gtk.gpointer) callconv(.c) void {
    _ = btn;
    const ctx: *MenuItemClickContext = @ptrCast(@alignCast(user_data orelse return));
    if (ctx.popover) |pop| {
        gtk.gtk_popover_popdown(@ptrCast(pop));
    }

    if (ctx.tray.conn) |c| {
        var err: ?*anyopaque = null;
        const param = gtk.g_variant_new_parsed("(%i, 'clicked', <0>, 0)", ctx.id);
        const res = gtk.g_dbus_connection_call_sync(
            c,
            ctx.service.ptr,
            ctx.menu_path.ptr,
            "com.canonical.dbusmenu",
            "Event",
            param,
            null,
            0,
            1000,
            null,
            &err,
        );
        if (res) |r| gtk.g_variant_unref(r) else if (err) |e| gtk.g_error_free(e);
    }
}

fn onMenuItemContextFree(data: gtk.gpointer) callconv(.c) void {
    const ctx: *MenuItemClickContext = @ptrCast(@alignCast(data orelse return));
    ctx.tray.allocator.free(ctx.service);
    ctx.tray.allocator.free(ctx.menu_path);
    ctx.tray.allocator.destroy(ctx);
}

pub const WatcherItemWatch = struct {
    tray: *TrayModule,
    bus_name: [:0]const u8,
    full_id: [:0]const u8,
    watch_id: c_uint,
};

pub const TrayModule = struct {
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

    pub fn create(allocator: Allocator, name_hint: []const u8, settings: ModuleSettings) !*TrayModule {
        _ = name_hint;
        const self = try allocator.create(TrayModule);
        errdefer allocator.destroy(self);

        const icon_size = @as(c_int, @intCast(settings.getInt("icon-size") orelse 16));
        const spacing = @as(c_int, @intCast(settings.getInt("spacing") orelse 4));
        const reverse = settings.getBool("reverse-direction") orelse false;
        const show_passive = settings.getBool("show-passive-items") orelse false;

        self.* = .{
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

        if (self.box) |b| {
            gtk.gtk_widget_set_name(b, "tray");
            gtk.gtk_widget_add_css_class(b, "tray");
        }

        var err: ?*anyopaque = null;
        self.conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.session), null, &err);
        if (self.conn) |c| {
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
                self.setupInternalWatcher(c);
            }

            self.sub_registered = gtk.g_dbus_connection_signal_subscribe(
                c,
                "org.kde.StatusNotifierWatcher",
                "org.kde.StatusNotifierWatcher",
                "StatusNotifierItemRegistered",
                "/StatusNotifierWatcher",
                null,
                0,
                @ptrCast(&onItemRegistered),
                self,
                null,
            );

            self.sub_unregistered = gtk.g_dbus_connection_signal_subscribe(
                c,
                "org.kde.StatusNotifierWatcher",
                "org.kde.StatusNotifierWatcher",
                "StatusNotifierItemUnregistered",
                "/StatusNotifierWatcher",
                null,
                0,
                @ptrCast(&onItemUnregistered),
                self,
                null,
            );

            self.fetchInitialItems();
        }

        return self;
    }

    pub fn deinit(self: *TrayModule) void {
        if (self.conn) |c| {
            if (self.watcher_object_id != 0) {
                _ = gtk.g_dbus_connection_unregister_object(c, self.watcher_object_id);
                self.watcher_object_id = 0;
            }
            if (self.sub_registered != 0) {
                gtk.g_dbus_connection_signal_unsubscribe(c, self.sub_registered);
                self.sub_registered = 0;
            }
            if (self.sub_unregistered != 0) {
                gtk.g_dbus_connection_signal_unsubscribe(c, self.sub_unregistered);
                self.sub_unregistered = 0;
            }
        }

        if (self.watcher_owned_id != 0) {
            gtk.g_bus_unown_name(self.watcher_owned_id);
            self.watcher_owned_id = 0;
        }

        if (self.watcher_node_info) |info| {
            gtk.g_dbus_node_info_unref(info);
            self.watcher_node_info = null;
        }

        for (self.watcher_watches.items) |w| {
            if (w.watch_id != 0) gtk.g_bus_unwatch_name(w.watch_id);
            self.allocator.free(w.bus_name);
            self.allocator.free(w.full_id);
            self.allocator.destroy(w);
        }
        self.watcher_watches.deinit(self.allocator);

        for (self.watcher_items.items) |it| {
            self.allocator.free(it);
        }
        self.watcher_items.deinit(self.allocator);

        for (self.items.items) |item| {
            if (item.button) |btn| {
                if (self.box) |b| {
                    gtk.gtk_box_remove(@ptrCast(b), btn);
                }
            }
            item.deinit();
        }
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn setupInternalWatcher(self: *TrayModule, conn: ?*gtk.GDBusConnection) void {
        const c = conn orelse return;
        var err: ?*anyopaque = null;

        self.watcher_node_info = gtk.g_dbus_node_info_new_for_xml(WATCHER_XML.ptr, &err);
        if (self.watcher_node_info) |info| {
            const iface = gtk.g_dbus_node_info_lookup_interface(info, "org.kde.StatusNotifierWatcher");
            if (iface != null) {
                self.watcher_object_id = gtk.g_dbus_connection_register_object(
                    c,
                    "/StatusNotifierWatcher",
                    iface,
                    &watcher_vtable,
                    self,
                    null,
                    &err,
                );
                debug.print("Registered D-Bus object /StatusNotifierWatcher (id={d})\n", .{self.watcher_object_id});
            }
        }

        self.watcher_owned_id = gtk.g_bus_own_name_on_connection(
            c,
            "org.kde.StatusNotifierWatcher",
            0,
            null,
            null,
            self,
            null,
        );
        debug.print("Claimed org.kde.StatusNotifierWatcher as standalone tray host\n", .{});
    }

    pub fn registerItemFromWatcher(self: *TrayModule, bus_name: []const u8, obj_path: []const u8) void {
        const full_id = fmt.allocPrint(self.allocator, "{s}{s}", .{ bus_name, obj_path }) catch return;
        defer self.allocator.free(full_id);

        for (self.watcher_items.items) |existing| {
            if (mem.eql(u8, existing, full_id)) return;
        }

        const full_id_dupe = self.allocator.dupe(u8, full_id) catch return;
        self.watcher_items.append(self.allocator, full_id_dupe) catch {
            self.allocator.free(full_id_dupe);
            return;
        };

        const bus_name_z = self.allocator.dupeSentinel(u8, bus_name, 0) catch return;
        const full_z = self.allocator.dupeSentinel(u8, full_id, 0) catch {
            self.allocator.free(bus_name_z);
            return;
        };

        const watch_ctx = self.allocator.create(WatcherItemWatch) catch {
            self.allocator.free(bus_name_z);
            self.allocator.free(full_z);
            return;
        };
        watch_ctx.* = .{
            .tray = self,
            .bus_name = bus_name_z,
            .full_id = full_z,
            .watch_id = 0,
        };

        if (self.conn) |c| {
            watch_ctx.watch_id = gtk.g_bus_watch_name_on_connection(
                c,
                bus_name_z.ptr,
                0,
                null,
                &onWatchedNameVanished,
                watch_ctx,
                null,
            );
            self.watcher_watches.append(self.allocator, watch_ctx) catch {};

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

        self.addItem(full_id);
    }

    fn fetchInitialItems(self: *TrayModule) void {
        const c = self.conn orelse return;
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
                    self.addItem(mem.span(s));
                }
            }
        }
    }

    pub fn addItem(self: *TrayModule, service_and_path: []const u8) void {
        if (service_and_path.len == 0) return;

        var service: []const u8 = service_and_path;
        var path: []const u8 = "/StatusNotifierItem";

        if (mem.findScalar(u8, service_and_path, '/')) |slash_idx| {
            service = service_and_path[0..slash_idx];
            path = service_and_path[slash_idx..];
        }

        for (self.items.items) |item| {
            if (mem.eql(u8, item.service, service) and mem.eql(u8, item.path, path)) {
                return;
            }
        }

        const service_z = self.allocator.dupeSentinel(u8, service, 0) catch return;
        errdefer self.allocator.free(service_z);
        const path_z = self.allocator.dupeSentinel(u8, path, 0) catch return;
        errdefer self.allocator.free(path_z);

        const c = self.conn orelse return;
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

        const item = self.allocator.create(TrayItem) catch {
            gtk.g_object_unref(proxy);
            return;
        };

        item.* = .{
            .allocator = self.allocator,
            .tray = self,
            .service = service_z,
            .path = path_z,
            .proxy = proxy,
            .conn = c,
        };

        const btn = gtk.gtk_button_new();
        gtk.gtk_button_set_has_frame(btn, 0);
        gtk.gtk_widget_add_css_class(btn, "tray-item");
        gtk.gtk_widget_add_css_class(btn, "item");
        gtk.gtk_widget_set_size_request(btn, self.icon_size, self.icon_size);
        gtk.gtk_widget_set_valign(btn, gtk.GTK_ALIGN_CENTER);
        gtk.gtk_widget_set_halign(btn, gtk.GTK_ALIGN_CENTER);

        const img = gtk.gtk_image_new();
        gtk.gtk_image_set_pixel_size(@ptrCast(img), self.icon_size);
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

        if (self.box) |b| {
            if (self.reverse_direction) {
                gtk.gtk_box_prepend(@ptrCast(b), btn);
            } else {
                gtk.gtk_box_append(@ptrCast(b), btn);
            }
        }

        self.items.append(self.allocator, item) catch {
            item.deinit();
            return;
        };
    }

    pub fn removeItem(self: *TrayModule, service_and_path: []const u8) void {
        var service = service_and_path;
        var path: []const u8 = "/StatusNotifierItem";
        if (mem.findScalar(u8, service_and_path, '/')) |slash_idx| {
            service = service_and_path[0..slash_idx];
            path = service_and_path[slash_idx..];
        }

        var i: usize = 0;
        while (i < self.items.items.len) {
            const item = self.items.items[i];
            if (mem.eql(u8, item.service, service) and (path.len == 0 or mem.eql(u8, item.path, path))) {
                if (item.button) |btn| {
                    if (self.box) |b| {
                        gtk.gtk_box_remove(@ptrCast(b), btn);
                    }
                }
                _ = self.items.swapRemove(i);
                item.deinit();
                return;
            } else {
                i += 1;
            }
        }
    }
};

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

const watcher_vtable = gtk.GDBusInterfaceVTable{
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
    const self: *TrayModule = @ptrCast(@alignCast(user_data orelse return));
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

                    self.registerItemFromWatcher(bus_name, obj_path);
                }
            }
        }
        gtk.g_dbus_method_invocation_return_value(invocation, null);
    } else if (mem.eql(u8, m_name, "RegisterStatusNotifierHost")) {
        if (self.conn) |c| {
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
    const self: *TrayModule = @ptrCast(@alignCast(user_data orelse return null));
    const p_name = mem.span(property_name);

    if (mem.eql(u8, p_name, "RegisteredStatusNotifierItems")) {
        var str_ptrs = self.allocator.alloc(?[*:0]const u8, self.watcher_items.items.len + 1) catch return null;
        defer self.allocator.free(str_ptrs);

        for (self.watcher_items.items, 0..) |it, idx| {
            const z = self.allocator.dupeSentinel(u8, it, 0) catch return null;
            str_ptrs[idx] = z.ptr;
        }
        defer {
            for (0..self.watcher_items.items.len) |idx| {
                if (str_ptrs[idx]) |ptr| self.allocator.free(mem.span(ptr));
            }
        }
        str_ptrs[self.watcher_items.items.len] = null;
        return gtk.g_variant_new_strv(@ptrCast(str_ptrs.ptr), @intCast(self.watcher_items.items.len));
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
            const pt = gtk.graphene_point_t{ .x = @floatCast(x), .y = @floatCast(y) };
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
    const self: *TrayModule = @ptrCast(@alignCast(user_data orelse return));
    if (parameters) |p| {
        const val = gtk.g_variant_get_child_value(p, 0);
        if (val) |v| {
            defer gtk.g_variant_unref(v);
            if (gtk.g_variant_get_string(v, null)) |str| {
                self.addItem(mem.span(str));
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
    const self: *TrayModule = @ptrCast(@alignCast(user_data orelse return));
    if (parameters) |p| {
        const val = gtk.g_variant_get_child_value(p, 0);
        if (val) |v| {
            defer gtk.g_variant_unref(v);
            if (gtk.g_variant_get_string(v, null)) |str| {
                self.removeItem(mem.span(str));
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
