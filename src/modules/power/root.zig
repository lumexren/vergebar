// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of vergebar.
//
// Copyright (c) 2026 lumexren

const PowerModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const ipc = @import("utils").ipc;
const bindings = @import("bindings");
const gdbus = bindings.gdbus;

base: *BaseModule,
allocator: Allocator,
format: []const u8,
popover: ?*gtk.GtkWidget = null,
system_bus: ?*gdbus.GDBusConnection = null,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*PowerModule {
    const this = try allocator.create(PowerModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "power", settings);
    errdefer this.base.deinit();

    this.allocator = allocator;
    this.format = try allocator.dupe(u8, settings.getString("format") orelse "⏻");
    this.popover = null;
    this.system_bus = gdbus.getBus(.system);

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.base.setText(this.format);
    this.base.setTooltip("Power & Session");

    return this;
}

pub fn deinit(this: *PowerModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    if (this.system_bus) |bus| {
        gdbus.g_object_unref(bus);
        this.system_bus = null;
    }
    this.allocator.free(this.format);

    const alloc = this.base.allocator;
    this.base.deinit();
    alloc.destroy(this);
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    _ = btn_num;
    const this: *PowerModule = @ptrCast(@alignCast(user_data orelse return false));
    this.togglePowerPopover();
    return true;
}

pub fn togglePowerPopover(this: *PowerModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 6);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "power-popover");

        const header = gtk.gtk_label_new("Power & Session");
        if (header) |h| {
            gtk.gtk_widget_add_css_class(h, "title");
            gtk.gtk_box_append(@ptrCast(b), h);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        const lock_btn = gtk.gtk_button_new_with_label("🔒 Lock");
        if (lock_btn) |lb| {
            _ = gtk.g_signal_connect_data(lb, "clicked", @ptrCast(&onLockClicked), this, null, 0);
            gtk.gtk_box_append(@ptrCast(b), lb);
        }

        const suspend_btn = gtk.gtk_button_new_with_label("󰒲 Suspend");
        if (suspend_btn) |sb| {
            _ = gtk.g_signal_connect_data(sb, "clicked", @ptrCast(&onSuspendClicked), this, null, 0);
            gtk.gtk_box_append(@ptrCast(b), sb);
        }

        const reboot_btn = gtk.gtk_button_new_with_label("󰜉 Reboot");
        if (reboot_btn) |rb| {
            _ = gtk.g_signal_connect_data(rb, "clicked", @ptrCast(&onRebootClicked), this, null, 0);
            gtk.gtk_box_append(@ptrCast(b), rb);
        }

        const poweroff_btn = gtk.gtk_button_new_with_label("⏻ Power Off");
        if (poweroff_btn) |pb| {
            gtk.gtk_widget_add_css_class(pb, "destructive-action");
            _ = gtk.g_signal_connect_data(pb, "clicked", @ptrCast(&onPowerOffClicked), this, null, 0);
            gtk.gtk_box_append(@ptrCast(b), pb);
        }

        const logout_btn = gtk.gtk_button_new_with_label("󰗼 Log Out");
        if (logout_btn) |lob| {
            _ = gtk.g_signal_connect_data(lob, "clicked", @ptrCast(&onLogoutClicked), this, null, 0);
            gtk.gtk_box_append(@ptrCast(b), lob);
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onLockClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *PowerModule = @ptrCast(@alignCast(user_data orelse return));
    _ = gtk.g_spawn_command_line_async("loginctl lock-session", null);
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onSuspendClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *PowerModule = @ptrCast(@alignCast(user_data orelse return));
    if (this.system_bus) |bus| {
        if (gdbus.g_variant_new_parsed("(true,)")) |params| {
            gdbus.callMethodFireAndForget(
                bus,
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
                "Suspend",
                params,
            );
        }
    }
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onRebootClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *PowerModule = @ptrCast(@alignCast(user_data orelse return));
    if (this.system_bus) |bus| {
        if (gdbus.g_variant_new_parsed("(true,)")) |params| {
            gdbus.callMethodFireAndForget(
                bus,
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
                "Reboot",
                params,
            );
        }
    }
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onPowerOffClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *PowerModule = @ptrCast(@alignCast(user_data orelse return));
    if (this.system_bus) |bus| {
        if (gdbus.g_variant_new_parsed("(true,)")) |params| {
            gdbus.callMethodFireAndForget(
                bus,
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
                "PowerOff",
                params,
            );
        }
    }
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onLogoutClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *PowerModule = @ptrCast(@alignCast(user_data orelse return));
    if (ipc.queryHyprlandSocket(this.allocator, "dispatch exit")) |resp| {
        this.allocator.free(resp);
    } else if (ipc.querySwaySocket(this.allocator, 0, "exit")) |resp| {
        this.allocator.free(resp);
    } else {
        _ = gtk.g_spawn_command_line_async("niri msg action quit --skip-confirmation", null);
    }
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}
