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

const SystemdFailedModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const fmt = std.fmt;
const gtk = @import("gtk");
const gdbus = @import("bindings").gdbus;
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const Template = @import("utils").Template;

const SYSTEMD_SERVICE = "org.freedesktop.systemd1";
const SYSTEMD_PATH = "/org/freedesktop/systemd1";
const SYSTEMD_MANAGER_IFACE = "org.freedesktop.systemd1.Manager";

const UnitActionContext = struct {
    unit_name: [:0]const u8,
    is_user: bool,
    allocator: Allocator,
    mod: *SystemdFailedModule,
};

const FailedUnitItem = struct {
    name: []const u8,
    desc: []const u8,
    is_user: bool,
};

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_ok: Template,
template_tooltip: ?Template = null,
format: []const u8,
format_ok: []const u8,
hide_on_ok: bool,
interval_sec: u32,
timer_id: u32 = 0,
system_conn: ?*gdbus.GDBusConnection = null,
user_conn: ?*gdbus.GDBusConnection = null,
popover: ?*gtk.GtkWidget = null,
unit_contexts: ArrayList(*UnitActionContext),

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*SystemdFailedModule {
    const this = try allocator.create(SystemdFailedModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "systemd-failed-units", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getString("format") orelse "✗ {nr_failed}";
    const format_ok_str = settings.getString("format-ok") orelse "✓";
    const hide_ok = settings.getBool("hide-on-ok") orelse false;
    const interval = @as(u32, @intCast(settings.getInt("interval") orelse 5));

    var tmpl: Template = try .compile(allocator, format_str);
    errdefer tmpl.deinit();
    var tmpl_ok: Template = try .compile(allocator, format_ok_str);
    errdefer tmpl_ok.deinit();

    const sys_conn = gdbus.getBus(.system);
    const usr_conn = gdbus.getBus(.session);

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .template = tmpl,
        .template_ok = tmpl_ok,
        .template_tooltip = if (base_mod.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null,
        .format = try allocator.dupe(u8, format_str),
        .format_ok = try allocator.dupe(u8, format_ok_str),
        .hide_on_ok = hide_ok,
        .interval_sec = interval,
        .system_conn = sys_conn,
        .user_conn = usr_conn,
        .popover = null,
        .unit_contexts = .empty,
    };

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.update();
    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *SystemdFailedModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    for (this.unit_contexts.items) |ctx| {
        this.allocator.free(ctx.unit_name);
        this.allocator.destroy(ctx);
    }
    this.unit_contexts.deinit(this.allocator);

    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template.deinit();
    this.template_ok.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    if (this.system_conn) |c| gdbus.g_object_unref(c);
    if (this.user_conn) |c| gdbus.g_object_unref(c);
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.allocator.free(this.format_ok);
    this.base.deinit();
    this.allocator.destroy(this);
}

fn countFailed(conn: ?*gdbus.GDBusConnection) usize {
    const c = conn orelse return 0;
    if (gdbus.getPropertySync(c, SYSTEMD_SERVICE, SYSTEMD_PATH, SYSTEMD_MANAGER_IFACE, "NFailedUnits")) |v| {
        defer gdbus.g_variant_unref(v);
        if (gdbus.asUint32(v)) |cnt| return cnt;
    }
    return 0;
}

pub fn update(this: *SystemdFailedModule) void {
    const n_sys = countFailed(this.system_conn);
    const n_usr = countFailed(this.user_conn);
    const total = n_sys + n_usr;

    if (this.hide_on_ok and total == 0) {
        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 0);
        return;
    } else {
        if (this.base.button) |btn| gtk.gtk_widget_set_visible(btn, 1);
    }

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKeyAny("nr_failed", @as(i64, @intCast(total))) catch {};
    replacer.addKeyAny("nr_failed_system", @as(i64, @intCast(n_sys))) catch {};
    replacer.addKeyAny("nr_failed_user", @as(i64, @intCast(n_usr))) catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = if (total == 0)
        this.template_ok.renderBuf(replacer, &render_buf) catch this.format_ok
    else
        this.template.renderBuf(replacer, &render_buf) catch this.format;

    this.base.setText(rendered);

    if (total > 0) {
        this.base.addCssClass("failed");
        this.base.removeCssClass("ok");
    } else {
        this.base.addCssClass("ok");
        this.base.removeCssClass("failed");
    }

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [128]u8 = undefined;
        const tt = if (total > 0)
            (mem.print(&tt_buf, "Failed Units: {d} (System: {d}, User: {d})", .{ total, n_sys, n_usr }) catch "Failed Units")
        else
            "All systemd units OK";
        this.base.setTooltip(tt);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *SystemdFailedModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    _ = btn_num;
    const this: *SystemdFailedModule = @ptrCast(@alignCast(user_data orelse return false));
    this.toggleFailedUnitsPopover();
    return true;
}

fn appendFailedUnitsFromBus(conn: ?*gdbus.GDBusConnection, is_user: bool, list: *ArrayList(FailedUnitItem), alloc: Allocator) void {
    const c = conn orelse return;
    const params = gdbus.g_variant_new_parsed("(['failed'],)") orelse return;
    const res = gdbus.callMethodSync(c, SYSTEMD_SERVICE, SYSTEMD_PATH, SYSTEMD_MANAGER_IFACE, "ListUnitsFiltered", params);
    if (res) |r| {
        defer gdbus.g_variant_unref(r);
        const outer = gdbus.g_variant_get_child_value(r, 0);
        if (outer) |out| {
            defer gdbus.g_variant_unref(out);
            const iter = gdbus.g_variant_iter_new(out);
            if (iter) |it| {
                defer gdbus.g_variant_iter_free(it);
                while (gdbus.g_variant_iter_next_value(it)) |entry| {
                    defer gdbus.g_variant_unref(entry);
                    const name_v = gdbus.g_variant_get_child_value(entry, 0);
                    const desc_v = gdbus.g_variant_get_child_value(entry, 1);
                    defer if (name_v) |nv| gdbus.g_variant_unref(nv);
                    defer if (desc_v) |dv| gdbus.g_variant_unref(dv);

                    if (name_v) |nv| {
                        if (desc_v) |dv| {
                            const name_z = gdbus.g_variant_get_string(nv, null);
                            const desc_z = gdbus.g_variant_get_string(dv, null);
                            const name_slice = alloc.dupe(u8, mem.span(name_z)) catch continue;
                            const desc_slice = alloc.dupe(u8, mem.span(desc_z)) catch {
                                alloc.free(name_slice);
                                continue;
                            };

                            list.append(alloc, .{
                                .name = name_slice,
                                .desc = desc_slice,
                                .is_user = is_user,
                            }) catch {
                                alloc.free(name_slice);
                                alloc.free(desc_slice);
                            };
                        }
                    }
                }
            }
        }
    }
}

pub fn toggleFailedUnitsPopover(this: *SystemdFailedModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    for (this.unit_contexts.items) |ctx| {
        this.allocator.free(ctx.unit_name);
        this.allocator.destroy(ctx);
    }
    this.unit_contexts.clearRetainingCapacity();

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "systemd-failed-popover");

        const header_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
        if (header_box) |hb| {
            const title = gtk.gtk_label_new("Systemd Failed Units");
            if (title) |t| {
                gtk.gtk_widget_add_css_class(t, "title");
                gtk.gtk_box_append(@ptrCast(hb), t);
            }

            const reset_all_btn = gtk.gtk_button_new_with_label("Reset Failed");
            if (reset_all_btn) |rb| {
                _ = gtk.g_signal_connect_data(rb, "clicked", @ptrCast(&onResetAllClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(hb), rb);
            }

            gtk.gtk_box_append(@ptrCast(b), hb);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        var failed_units: ArrayList(FailedUnitItem) = .empty;
        defer {
            for (failed_units.items) |u| {
                this.allocator.free(u.name);
                this.allocator.free(u.desc);
            }
            failed_units.deinit(this.allocator);
        }

        appendFailedUnitsFromBus(this.system_conn, false, &failed_units, this.allocator);
        appendFailedUnitsFromBus(this.user_conn, true, &failed_units, this.allocator);

        if (failed_units.items.len == 0) {
            const empty_lbl = gtk.gtk_label_new("No failed units detected");
            if (empty_lbl) |el| gtk.gtk_box_append(@ptrCast(b), el);
        } else {
            const scroll = gtk.gtk_scrolled_window_new();
            if (scroll) |sc| {
                gtk.gtk_scrolled_window_set_max_content_height(sc, 350);
                gtk.gtk_scrolled_window_set_propagate_natural_height(sc, 1);

                const list_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 6);
                if (list_box) |lb| {
                    for (failed_units.items) |u| {
                        const item_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
                        if (item_box) |ib| {
                            const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 6);
                            if (row) |r| {
                                var name_buf: [128]u8 = undefined;
                                const scope_prefix = if (u.is_user) "[user] " else "[sys] ";
                                if (mem.printSentinel(&name_buf, "{s}{s}", .{ scope_prefix, u.name }, 0)) |full_title| {
                                    const name_lbl = gtk.gtk_label_new(full_title.ptr);
                                    if (name_lbl) |nl| {
                                        gtk.gtk_widget_add_css_class(nl, "subtitle");
                                        gtk.gtk_box_append(@ptrCast(r), nl);
                                    }
                                } else |_| {}

                                const restart_btn = gtk.gtk_button_new_with_label("󰜉 Restart");
                                if (restart_btn) |rb| {
                                    const ctx = this.allocator.create(UnitActionContext) catch continue;
                                    ctx.* = .{
                                        .unit_name = this.allocator.dupeSentinel(u8, u.name, 0) catch {
                                            this.allocator.destroy(ctx);
                                            continue;
                                        },
                                        .is_user = u.is_user,
                                        .allocator = this.allocator,
                                        .mod = this,
                                    };
                                    this.unit_contexts.append(this.allocator, ctx) catch {
                                        this.allocator.free(ctx.unit_name);
                                        this.allocator.destroy(ctx);
                                        continue;
                                    };

                                    _ = gtk.g_signal_connect_data(rb, "clicked", @ptrCast(&onRestartUnitClicked), ctx, null, 0);
                                    gtk.gtk_box_append(@ptrCast(r), rb);
                                }

                                gtk.gtk_box_append(@ptrCast(ib), r);
                            }

                            if (u.desc.len > 0) {
                                var desc_buf: [256]u8 = undefined;
                                const desc_z = mem.printSentinel(&desc_buf, "{s}", .{u.desc}, 0) catch "";
                                if (desc_z.len > 0) {
                                    const desc_lbl = gtk.gtk_label_new(desc_z.ptr);
                                    if (desc_lbl) |dl| {
                                        gtk.gtk_widget_set_opacity(dl, 0.7);
                                        gtk.gtk_box_append(@ptrCast(ib), dl);
                                    }
                                }
                            }

                            gtk.gtk_box_append(@ptrCast(lb), ib);
                        }
                    }

                    gtk.gtk_scrolled_window_set_child(sc, lb);
                }

                gtk.gtk_box_append(@ptrCast(b), sc);
            }
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onRestartUnitClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const ctx: *UnitActionContext = @ptrCast(@alignCast(user_data orelse return));
    const conn = if (ctx.is_user) ctx.mod.user_conn else ctx.mod.system_conn;
    if (conn) |c| {
        var arg_buf: [256]u8 = undefined;
        const arg_z = mem.printSentinel(&arg_buf, "('{s}', 'replace')", .{ctx.unit_name}, 0) catch return;
        if (gdbus.g_variant_new_parsed(arg_z)) |params| {
            gdbus.callMethodFireAndForget(
                c,
                SYSTEMD_SERVICE,
                SYSTEMD_PATH,
                SYSTEMD_MANAGER_IFACE,
                "RestartUnit",
                params,
            );
        }
    }
    ctx.mod.update();
    if (ctx.mod.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onResetAllClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *SystemdFailedModule = @ptrCast(@alignCast(user_data orelse return));
    if (this.system_conn) |c| {
        gdbus.callMethodFireAndForget(c, SYSTEMD_SERVICE, SYSTEMD_PATH, SYSTEMD_MANAGER_IFACE, "ResetFailed", null);
    }
    if (this.user_conn) |c| {
        gdbus.callMethodFireAndForget(c, SYSTEMD_SERVICE, SYSTEMD_PATH, SYSTEMD_MANAGER_IFACE, "ResetFailed", null);
    }
    this.update();
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}
