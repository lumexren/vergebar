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

const TrayItem = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const gtk = @import("gtk");
const TrayModule = @import("root.zig");
const MenuItemClickContext = @import("MenuItemClickContext.zig");

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

pub fn deinit(this: *TrayItem) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }

    if (this.conn) |c| {
        if (this.sig_icon != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sig_icon);
        if (this.sig_attention_icon != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sig_attention_icon);
        if (this.sig_overlay_icon != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sig_overlay_icon);
        if (this.sig_title != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sig_title);
        if (this.sig_status != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sig_status);
        if (this.sig_tooltip != 0) gtk.g_dbus_connection_signal_unsubscribe(c, this.sig_tooltip);
        this.sig_icon = 0;
        this.sig_attention_icon = 0;
        this.sig_overlay_icon = 0;
        this.sig_title = 0;
        this.sig_status = 0;
        this.sig_tooltip = 0;
    }

    if (this.proxy) |p| {
        gtk.g_object_unref(p);
        this.proxy = null;
    }

    if (this.menu_path) |mp| this.allocator.free(mp);
    if (this.title) |t| this.allocator.free(t);
    if (this.icon_name) |i| this.allocator.free(i);
    if (this.status) |s| this.allocator.free(s);
    this.allocator.free(this.service);
    this.allocator.free(this.path);
    this.allocator.destroy(this);
}

pub fn updateMenuPath(this: *TrayItem) void {
    const p = this.proxy orelse return;
    const menu_prop = gtk.g_dbus_proxy_get_cached_property(p, "Menu");
    if (menu_prop) |mp| {
        defer gtk.g_variant_unref(mp);
        if (gtk.g_variant_get_string(mp, null)) |path_ptr| {
            const path_str = mem.span(path_ptr);
            if (path_str.len > 0) {
                if (this.menu_path) |old| this.allocator.free(old);
                this.menu_path = this.allocator.dupeSentinel(u8, path_str, 0) catch null;
            }
        }
    }
}

pub fn updateIcon(this: *TrayItem) void {
    const p = this.proxy orelse return;

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
                if (this.icon_name) |old| this.allocator.free(old);
                this.icon_name = this.allocator.dupeSentinel(u8, name, 0) catch null;
                if (this.image) |img| {
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
                if (this.image) |img| {
                    gtk.gtk_image_set_from_icon_name(@ptrCast(img), name_ptr);
                }
                return;
            }
        }
    }

    const pixmap_prop = gtk.g_dbus_proxy_get_cached_property(p, "IconPixmap");
    if (pixmap_prop) |px| {
        defer gtk.g_variant_unref(px);
        if (this.tryLoadPixmap(px)) {
            return;
        }
    }

    const attn_pix = gtk.g_dbus_proxy_get_cached_property(p, "AttentionIconPixmap");
    if (attn_pix) |apx| {
        defer gtk.g_variant_unref(apx);
        if (this.tryLoadPixmap(apx)) {
            return;
        }
    }

    if (this.image) |img| {
        gtk.gtk_image_set_from_icon_name(@ptrCast(img), "application-x-executable");
    }
}

fn tryLoadPixmap(this: *TrayItem, pixmap_val: ?*gtk.GVariant) bool {
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
                if (best_data == null or @abs(w - this.tray.icon_size) < @abs(best_width - this.tray.icon_size)) {
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
                if (this.image) |img| {
                    gtk.gtk_image_set_from_paintable(@ptrCast(img), tex);
                    return true;
                }
            }
        }
    }

    return false;
}

pub fn updateTitle(this: *TrayItem) void {
    const p = this.proxy orelse return;
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
        if (this.button) |btn| {
            gtk.gtk_widget_set_tooltip_text(btn, t);
        }
    }
}

pub fn updateStatus(this: *TrayItem) void {
    const p = this.proxy orelse return;
    const status_prop = gtk.g_dbus_proxy_get_cached_property(p, "Status");
    if (status_prop) |sp| {
        defer gtk.g_variant_unref(sp);
        if (gtk.g_variant_get_string(sp, null)) |st| {
            const st_slice = mem.span(st);
            if (this.button) |btn| {
                if (mem.eql(u8, st_slice, "Passive")) {
                    gtk.gtk_widget_add_css_class(btn, "passive");
                    gtk.gtk_widget_remove_css_class(btn, "active");
                    gtk.gtk_widget_remove_css_class(btn, "needs-attention");
                    gtk.gtk_widget_set_visible(btn, if (this.tray.show_passive) 1 else 0);
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

pub fn openMenu(this: *TrayItem) void {
    const mp = this.menu_path orelse return;
    const c = this.conn orelse return;
    const btn_widget = this.button orelse return;

    var err: ?*anyopaque = null;
    const about_res = gtk.g_dbus_connection_call_sync(
        c,
        this.service.ptr,
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
        this.service.ptr,
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

    if (this.popover) |old_pop| {
        gtk.gtk_widget_unparent(old_pop);
        this.popover = null;
    }

    const pop = gtk.gtk_popover_new();
    if (pop == null) return;
    gtk.gtk_widget_set_parent(pop, btn_widget);
    this.popover = pop;

    _ = gtk.g_signal_connect_data(
        pop,
        "closed",
        @ptrCast(&onPopoverClosed),
        this,
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

        const click_ctx = this.allocator.create(MenuItemClickContext) catch continue;
        click_ctx.* = .{
            .tray = this.tray,
            .service = this.allocator.dupeSentinel(u8, this.service, 0) catch {
                this.allocator.destroy(click_ctx);
                continue;
            },
            .menu_path = this.allocator.dupeSentinel(u8, mp, 0) catch {
                this.allocator.free(click_ctx.service);
                this.allocator.destroy(click_ctx);
                continue;
            },
            .popover = pop,
            .id = item_id,
        };

        _ = gtk.g_signal_connect_data(
            item_btn,
            "clicked",
            @ptrCast(&MenuItemClickContext.onClicked),
            click_ctx,
            @ptrCast(&MenuItemClickContext.onFree),
            0,
        );

        gtk.gtk_box_append(@ptrCast(menu_box), item_btn);
    }

    gtk.gtk_popover_set_child(@ptrCast(pop), menu_box);
    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onPopoverClosed(popover: ?*gtk.GtkPopover, user_data: gtk.gpointer) callconv(.c) void {
    _ = popover;
    const item: *TrayItem = @ptrCast(@alignCast(user_data orelse return));
    if (item.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        item.popover = null;
    }
}
