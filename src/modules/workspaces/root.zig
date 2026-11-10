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

const WorkspacesModule = @This();

pub const Compositor = @import("Compositor.zig").Compositor;
pub const WorkspaceButton = @import("WorkspaceButton.zig");

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Thread = std.Thread;
const atomic = std.atomic;
const debug = std.debug;
const json = std.json;
const posix = std.posix;
const gtk = @import("gtk");
const ModuleSettings = @import("utils").Config.ModuleSettings;

const sh = @import("utils").sh;
const env = @import("utils").env;
const ipc = @import("utils").ipc;
const queryHyprlandSocket = ipc.queryHyprlandSocket;
const querySwaySocket = ipc.querySwaySocket;

const sockaddr_un = posix.sockaddr.un;

io: Io,
allocator: Allocator,
box: ?*gtk.GtkWidget,
buttons: ArrayList(WorkspaceButton),
active_id: i32 = 1,
compositor: Compositor,
format_icons: std.StringHashMap([]const u8),
default_icon: ?[]const u8 = null,
active_icon: ?[]const u8 = null,
urgent_icon: ?[]const u8 = null,
persistent_workspaces: i32 = 0,
all_outputs: bool = true,
timer_id: u32 = 0,
dbus_conn: ?*gtk.GDBusConnection = null,
kwin_sub_id: c_uint = 0,
event_thread: ?Thread = null,
event_sock_fd: atomic.Value(posix.fd_t) = .init(-1),
running: atomic.Value(bool) = .init(true),

pub fn getIconForWorkspace(this: *WorkspacesModule, ws_id: i32, is_active: bool) []const u8 {
    if (is_active and this.active_icon != null) return this.active_icon.?;

    var id_buf: [16]u8 = undefined;
    const id_str = mem.print(&id_buf, "{d}", .{ws_id}) catch "1";
    if (this.format_icons.get(id_str)) |ic| return ic;
    if (this.default_icon) |d| return d;
    return "";
}

pub fn create(io: Io, allocator: Allocator, name_hint: []const u8, settings: ModuleSettings) !*WorkspacesModule {
    const comp = Compositor.detect(name_hint);
    debug.print("Workspaces module initialized with compositor: {s}\n", .{comp.name()});

    const this = try allocator.create(WorkspacesModule);
    errdefer allocator.destroy(this);

    var icons_map: std.StringHashMap([]const u8) = .init(allocator);
    errdefer icons_map.deinit();

    var def_icon: ?[]const u8 = null;
    var act_icon: ?[]const u8 = null;
    var urg_icon: ?[]const u8 = null;

    if (settings.value == .object and settings.value.object.get("format-icons") != null) {
        const fi = settings.value.object.get("format-icons").?;
        if (fi == .object) {
            var it = fi.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    const key = entry.key_ptr.*;
                    const val = entry.value_ptr.*.string;
                    if (mem.eql(u8, key, "default")) {
                        def_icon = try allocator.dupe(u8, val);
                    } else if (mem.eql(u8, key, "active")) {
                        act_icon = try allocator.dupe(u8, val);
                    } else if (mem.eql(u8, key, "urgent")) {
                        urg_icon = try allocator.dupe(u8, val);
                    } else {
                        const k_dupe = try allocator.dupe(u8, key);
                        const v_dupe = try allocator.dupe(u8, val);
                        try icons_map.put(k_dupe, v_dupe);
                    }
                }
            }
        }
    }

    var persistent_ws: i32 = 0;
    if (settings.getInt("persistent-workspaces")) |p| {
        persistent_ws = @intCast(p);
    } else if (settings.value == .object and settings.value.object.get("persistent-workspaces") != null) {
        const pw = settings.value.object.get("persistent-workspaces").?;
        if (pw == .object) {
            persistent_ws = @intCast(pw.object.count());
        }
    }

    const all_outputs = settings.getBool("all-outputs") orelse true;

    this.* = .{
        .io = io,
        .allocator = allocator,
        .box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 2),
        .buttons = .empty,
        .compositor = comp,
        .format_icons = icons_map,
        .default_icon = def_icon,
        .active_icon = act_icon,
        .urgent_icon = urg_icon,
        .persistent_workspaces = persistent_ws,
        .all_outputs = all_outputs,
    };

    if (this.box) |b| {
        gtk.gtk_widget_set_name(b, "workspaces");
        gtk.gtk_widget_add_css_class(b, "workspaces");

        const scroll = gtk.gtk_event_controller_scroll_new(gtk.GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
        _ = gtk.g_signal_connect_data(
            scroll,
            "scroll",
            @ptrCast(&onWorkspacesScrolled),
            this,
            null,
            0,
        );
        gtk.gtk_widget_add_controller(b, scroll);
    }

    if (this.compositor == .kde) {
        var err: ?*anyopaque = null;
        this.dbus_conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.session), null, &err);
        if (this.dbus_conn) |conn| {
            this.kwin_sub_id = gtk.g_dbus_connection_signal_subscribe(
                conn,
                "org.kde.KWin",
                "org.kde.KWin.VirtualDesktopManager",
                null,
                "/VirtualDesktopManager",
                null,
                0,
                @ptrCast(&onKdeSignal),
                this,
                null,
            );
        }
    }

    this.rebuildButtons();
    this.update();

    switch (this.compositor) {
        .hyprland => {
            this.event_thread = Thread.spawn(.{}, hyprlandWorker, .{this}) catch null;
        },
        .sway => {
            this.event_thread = Thread.spawn(.{}, swayWorker, .{this}) catch null;
        },
        .niri => {
            this.event_thread = Thread.spawn(.{}, niriWorker, .{this}) catch null;
        },
        .kde, .river, .dwl, .wayfire, .mango, .generic => {},
    }

    this.timer_id = gtk.g_timeout_add_seconds(2, @ptrCast(&onHeartbeat), this);

    return this;
}

pub fn deinit(this: *WorkspacesModule) void {
    this.running.store(false, .seq_cst);
    const sock = this.event_sock_fd.swap(-1, .seq_cst);
    if (sock >= 0) {
        _ = posix.system.shutdown(sock, posix.SHUT.RDWR);
        _ = posix.system.close(sock);
    }

    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }

    if (this.compositor == .kde) {
        if (this.dbus_conn) |conn| {
            if (this.kwin_sub_id != 0) {
                gtk.g_dbus_connection_signal_unsubscribe(conn, this.kwin_sub_id);
                this.kwin_sub_id = 0;
            }
        }
    }

    if (this.event_thread) |thread| {
        thread.join();
        this.event_thread = null;
    }

    this.clearButtons();
    this.buttons.deinit(this.allocator);

    var it = this.format_icons.iterator();
    while (it.next()) |entry| {
        this.allocator.free(entry.key_ptr.*);
        this.allocator.free(entry.value_ptr.*);
    }
    this.format_icons.deinit();
    if (this.default_icon) |d| this.allocator.free(d);
    if (this.active_icon) |a| this.allocator.free(a);
    if (this.urgent_icon) |u| this.allocator.free(u);

    this.allocator.destroy(this);
}

pub fn clearButtons(this: *WorkspacesModule) void {
    if (this.box) |b| {
        for (this.buttons.items) |ws| {
            if (ws.button) |btn| {
                gtk.gtk_box_remove(@ptrCast(b), btn);
            }
        }
    }
    this.buttons.clearRetainingCapacity();
}

pub fn rebuildButtons(this: *WorkspacesModule) void {
    this.clearButtons();
    const count = this.getWorkspaceCount();

    var i: i32 = 1;
    while (i <= count) : (i += 1) {
        const btn = gtk.gtk_button_new();
        gtk.gtk_button_set_has_frame(btn, 0);

        const icon = this.getIconForWorkspace(i, i == this.active_id);
        var lbl_buf: [64]u8 = undefined;
        const lbl_text = if (icon.len > 0)
            mem.printSentinel(&lbl_buf, "{s}", .{icon}, 0) catch ""
        else
            mem.printSentinel(&lbl_buf, "{d}", .{i}, 0) catch "1";
        const lbl = gtk.gtk_label_new(lbl_text.ptr);
        gtk.gtk_button_set_child(btn, lbl);

        gtk.gtk_widget_add_css_class(btn, "workspace-button");
        if (i == this.active_id) {
            gtk.gtk_widget_add_css_class(btn, "active");
            gtk.gtk_widget_add_css_class(btn, "focused");
        }
        if (this.box) |b| {
            gtk.gtk_box_append(@ptrCast(b), btn);
        }

        const userdata = @as(usize, @intCast(i)) | (@as(usize, @backingInt(this.compositor)) << 32);

        _ = gtk.g_signal_connect_data(
            btn,
            "clicked",
            @ptrCast(&onWorkspaceClicked),
            @ptrFromInt(userdata),
            null,
            0,
        );

        this.buttons.append(this.allocator, .{
            .button = btn,
            .label = lbl,
            .id = i,
        }) catch break;
    }
}

fn getWorkspaceCount(this: *WorkspacesModule) i32 {
    var max_id: i32 = 0;
    if (this.compositor == .hyprland) {
        const out_opt = queryHyprlandSocket(this.allocator, "j/workspaces") orelse
            (sh.runAlloc(this.io, this.allocator, "hyprctl workspaces -j 2>/dev/null") catch null);
        if (out_opt) |out| {
            defer this.allocator.free(out);
            if (json.parseFromSlice(json.Value, this.allocator, out, .{})) |parsed| {
                defer parsed.deinit();
                if (parsed.value == .array) {
                    for (parsed.value.array.items) |ws| {
                        if (ws == .object) {
                            if (ws.object.get("id")) |id_v| {
                                if (id_v == .integer and id_v.integer > max_id) {
                                    max_id = @intCast(id_v.integer);
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        }
    } else if (this.compositor == .sway) {
        const out_opt = querySwaySocket(this.allocator, 1, "") orelse
            (sh.runAlloc(this.io, this.allocator, "swaymsg -t get_workspaces 2>/dev/null") catch null);
        if (out_opt) |out| {
            defer this.allocator.free(out);
            if (json.parseFromSlice(json.Value, this.allocator, out, .{})) |parsed| {
                defer parsed.deinit();
                if (parsed.value == .array) {
                    for (parsed.value.array.items) |ws| {
                        if (ws == .object) {
                            if (ws.object.get("num")) |num_v| {
                                if (num_v == .integer and num_v.integer > max_id) {
                                    max_id = @intCast(num_v.integer);
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        }
    } else if (this.compositor == .kde) {
        if (this.dbus_conn) |conn| {
            const res = gtk.g_dbus_connection_call_sync(
                conn,
                "org.kde.KWin",
                "/VirtualDesktopManager",
                "org.freedesktop.DBus.Properties",
                "Get",
                gtk.g_variant_new_parsed("('org.kde.KWin.VirtualDesktopManager', 'count')"),
                null,
                0,
                1000,
                null,
                null,
            );
            if (res) |r| {
                defer gtk.g_variant_unref(r);
                const c1 = gtk.g_variant_get_child_value(r, 0);
                if (c1) |child1| {
                    defer gtk.g_variant_unref(child1);
                    const c2 = gtk.g_variant_get_child_value(child1, 0);
                    if (c2) |child2| {
                        defer gtk.g_variant_unref(child2);
                        const count = gtk.g_variant_get_uint32(child2);
                        if (count >= 1) max_id = @intCast(count);
                    }
                }
            }
        }
    }

    if (max_id < this.persistent_workspaces) max_id = this.persistent_workspaces;
    if (max_id < 1) max_id = 5;
    return max_id;
}

pub fn update(this: *WorkspacesModule) void {
    var active_id: i32 = this.active_id;

    switch (this.compositor) {
        .kde => {
            if (this.dbus_conn) |conn| {
                const res = gtk.g_dbus_connection_call_sync(
                    conn,
                    "org.kde.KWin",
                    "/KWin",
                    "org.kde.KWin",
                    "currentDesktop",
                    null,
                    null,
                    0,
                    1000,
                    null,
                    null,
                );
                if (res) |r| {
                    defer gtk.g_variant_unref(r);
                    const child = gtk.g_variant_get_child_value(r, 0);
                    if (child) |c| {
                        defer gtk.g_variant_unref(c);
                        active_id = gtk.g_variant_get_int32(c);
                    }
                }
            }
        },
        .hyprland => {
            const out_opt = queryHyprlandSocket(this.allocator, "j/activeworkspace") orelse
                (sh.runAlloc(this.io, this.allocator, "hyprctl activeworkspace -j 2>/dev/null") catch null);
            if (out_opt) |out| {
                defer this.allocator.free(out);
                if (json.parseFromSlice(json.Value, this.allocator, out, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("id")) |id_val| {
                            if (id_val == .integer) {
                                active_id = @intCast(id_val.integer);
                            }
                        }
                    }
                } else |_| {}
            }
        },
        .sway => {
            const out_opt = querySwaySocket(this.allocator, 1, "") orelse
                (sh.runAlloc(this.io, this.allocator, "swaymsg -t get_workspaces 2>/dev/null") catch null);
            if (out_opt) |out| {
                defer this.allocator.free(out);
                if (json.parseFromSlice(json.Value, this.allocator, out, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .array) {
                        for (parsed.value.array.items) |ws| {
                            if (ws == .object) {
                                if (ws.object.get("focused")) |f| {
                                    if (f == .bool and f.bool) {
                                        if (ws.object.get("num")) |num_val| {
                                            if (num_val == .integer) active_id = @intCast(num_val.integer);
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                    }
                } else |_| {}
            }
        },
        .niri => {
            if (sh.runAlloc(this.io, this.allocator, "niri msg --json workspaces 2>/dev/null")) |out| {
                defer this.allocator.free(out);
                if (json.parseFromSlice(json.Value, this.allocator, out, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .array) {
                        for (parsed.value.array.items) |ws| {
                            if (ws == .object) {
                                if (ws.object.get("is_active")) |f| {
                                    if (f == .bool and f.bool) {
                                        if (ws.object.get("idx")) |idx_val| {
                                            if (idx_val == .integer) active_id = @intCast(idx_val.integer);
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                    }
                } else |_| {}
            } else |_| {}
        },
        .river => {
            var buf: [32]u8 = undefined;
            const len = sh.runBuf(this.io, "riverctl get-focused-tags 2>/dev/null", &buf);
            if (len > 0) {
                if (fmt.parseInt(u32, mem.trim(u8, buf[0..len], " \r\n\t"), 10)) |mask| {
                    var bit: i32 = 0;
                    while (bit < 32) : (bit += 1) {
                        if ((mask & (@as(u32, 1) << @intCast(bit))) != 0) {
                            active_id = bit + 1;
                            break;
                        }
                    }
                } else |_| {}
            }
        },
        .dwl => {
            var buf: [32]u8 = undefined;
            const len = sh.runBuf(this.io, "dwl-msg get_tags 2>/dev/null", &buf);
            if (len > 0) {
                if (fmt.parseInt(i32, mem.trim(u8, buf[0..len], " \r\n\t"), 10)) |t| {
                    active_id = t;
                } else |_| {}
            }
        },
        .wayfire => {
            var buf: [32]u8 = undefined;
            const len = sh.runBuf(this.io, "wayfire-msg get_active_workspace 2>/dev/null", &buf);
            if (len > 0) {
                if (fmt.parseInt(i32, mem.trim(u8, buf[0..len], " \r\n\t"), 10)) |ws| {
                    active_id = ws;
                } else |_| {}
            }
        },
        .mango => {
            var buf: [32]u8 = undefined;
            const len = sh.runBuf(this.io, "mangoc get-active-workspace 2>/dev/null", &buf);
            if (len > 0) {
                if (fmt.parseInt(i32, mem.trim(u8, buf[0..len], " \r\n\t"), 10)) |ws| {
                    active_id = ws;
                } else |_| {}
            }
        },
        .generic => {},
    }

    this.active_id = active_id;
    this.applyActiveClass();
}

pub fn applyActiveClass(this: *WorkspacesModule) void {
    for (this.buttons.items) |ws| {
        if (ws.button) |btn| {
            const is_active = (ws.id == this.active_id);
            if (is_active) {
                gtk.gtk_widget_add_css_class(btn, "active");
                gtk.gtk_widget_add_css_class(btn, "focused");
            } else {
                gtk.gtk_widget_remove_css_class(btn, "active");
                gtk.gtk_widget_remove_css_class(btn, "focused");
            }

            if (ws.label) |lbl| {
                const icon = this.getIconForWorkspace(ws.id, is_active);
                var lbl_buf: [64]u8 = undefined;
                const lbl_text = if (icon.len > 0)
                    mem.printSentinel(&lbl_buf, "{s}", .{icon}, 0) catch ""
                else
                    mem.printSentinel(&lbl_buf, "{d}", .{ws.id}, 0) catch "1";
                gtk.gtk_label_set_text(lbl, lbl_text.ptr);
            }
        }
    }
}

fn onDirectActiveChanged(user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const this: *WorkspacesModule = @ptrCast(@alignCast(user_data orelse return 0));
    if (!this.running.load(.seq_cst)) return 0;
    this.applyActiveClass();
    return 0;
}

fn onHeartbeat(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *WorkspacesModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onEventTrigger(user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const this: *WorkspacesModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 0;
}

fn onKdeSignal(
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
    _ = parameters;
    const this: *WorkspacesModule = @ptrCast(@alignCast(user_data orelse return));
    const sig = if (signal_name) |s| mem.span(s) else "";

    if (mem.eql(u8, sig, "countChanged") or mem.eql(u8, sig, "desktopCreated") or mem.eql(u8, sig, "desktopRemoved")) {
        this.rebuildButtons();
    }
    this.update();
}

fn onWorkspaceClicked(button: ?*gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const packed_data: usize = @intFromPtr(user_data);
    const ws_id: i32 = @intCast(packed_data & 0xFFFFFFFF);
    const comp: Compositor = @fromBackingInt(@intCast(@as(u32, @intCast(packed_data >> 32))));

    var cmd_buf: [128]u8 = undefined;
    var cmd: ?[:0]const u8 = null;

    switch (comp) {
        .kde => {
            var err: ?*anyopaque = null;
            const conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.session), null, &err);
            if (conn) |c| {
                const call_res = gtk.g_dbus_connection_call_sync(
                    c,
                    "org.kde.KWin",
                    "/KWin",
                    "org.kde.KWin",
                    "setCurrentDesktop",
                    gtk.g_variant_new_parsed("(%i,)", ws_id),
                    null,
                    0,
                    1000,
                    null,
                    &err,
                );
                if (call_res) |cr| gtk.g_variant_unref(cr);
            }
            return;
        },
        .hyprland => {
            var payload_buf: [32]u8 = undefined;
            const payload = mem.print(&payload_buf, "dispatch workspace {d}", .{ws_id}) catch return;
            if (queryHyprlandSocket(std.heap.c_allocator, payload)) |resp| {
                std.heap.c_allocator.free(resp);
                return;
            }
        },
        .sway => {
            var payload_buf: [32]u8 = undefined;
            const payload = mem.print(&payload_buf, "workspace {d}", .{ws_id}) catch return;
            if (querySwaySocket(std.heap.c_allocator, 0, payload)) |resp| {
                std.heap.c_allocator.free(resp);
                return;
            }
        },
        .niri => {
            const str = mem.print(&cmd_buf, "niri msg action focus-workspace {d}", .{ws_id}) catch return;
            cmd_buf[str.len] = 0;
            cmd = cmd_buf[0..str.len :0];
        },
        .river => {
            const mask: u32 = @as(u32, 1) << @intCast(@max(0, ws_id - 1));
            const str = mem.print(&cmd_buf, "riverctl set-focused-tags {d}", .{mask}) catch return;
            cmd_buf[str.len] = 0;
            cmd = cmd_buf[0..str.len :0];
        },
        .dwl => {
            const str = mem.print(&cmd_buf, "dwl-msg set_tags {d}", .{ws_id}) catch return;
            cmd_buf[str.len] = 0;
            cmd = cmd_buf[0..str.len :0];
        },
        .wayfire => {
            const str = mem.print(&cmd_buf, "wayfire-msg set_workspace {d}", .{ws_id}) catch return;
            cmd_buf[str.len] = 0;
            cmd = cmd_buf[0..str.len :0];
        },
        .mango => {
            const str = mem.print(&cmd_buf, "mangoc set-workspace {d}", .{ws_id}) catch return;
            cmd_buf[str.len] = 0;
            cmd = cmd_buf[0..str.len :0];
        },
        .generic => {},
    }

    if (cmd) |c| {
        _ = gtk.g_spawn_command_line_async(c.ptr, null);
    }
}

fn onWorkspacesScrolled(controller: ?*gtk.GtkEventControllerScroll, dx: f64, dy: f64, user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    _ = controller;
    _ = dx;
    const this: *WorkspacesModule = @ptrCast(@alignCast(user_data orelse return 0));

    const forward = dy < 0;

    switch (this.compositor) {
        .hyprland => {
            const payload = if (forward) "dispatch workspace e+1" else "dispatch workspace e-1";
            if (queryHyprlandSocket(this.allocator, payload)) |resp| {
                this.allocator.free(resp);
            }
            return 1;
        },
        .sway => {
            const payload = if (forward) "workspace next" else "workspace prev";
            const resp = querySwaySocket(this.allocator, 0, payload);
            if (resp) |r| this.allocator.free(r);
            return 1;
        },
        .niri => {
            const cmd = if (forward) "niri msg action focus-workspace-down" else "niri msg action focus-workspace-up";
            _ = gtk.g_spawn_command_line_async(cmd, null);
            return 1;
        },
        .kde => {
            if (this.dbus_conn) |conn| {
                const target = if (forward) this.active_id + 1 else this.active_id - 1;
                if (target >= 1) {
                    var err: ?*anyopaque = null;
                    const call_res = gtk.g_dbus_connection_call_sync(
                        conn,
                        "org.kde.KWin",
                        "/KWin",
                        "org.kde.KWin",
                        "setCurrentDesktop",
                        gtk.g_variant_new_parsed("(%i,)", target),
                        null,
                        0,
                        1000,
                        null,
                        &err,
                    );
                    if (call_res) |cr| gtk.g_variant_unref(cr);
                }
            }
            return 1;
        },
        else => return 0,
    }
}

fn hyprlandWorker(this: *WorkspacesModule) void {
    const io = this.io;
    while (this.running.load(.seq_cst)) {
        const xdg = env.get("XDG_RUNTIME_DIR") orelse "/run/user/1000";
        const sig = env.get("HYPRLAND_INSTANCE_SIGNATURE") orelse {
            sh.sleepSeconds(io, 2);
            continue;
        };

        var path_buf: [108]u8 = undefined;
        const sock_path = mem.print(&path_buf, "{s}/hypr/{s}/.socket2.sock", .{ xdg, sig }) catch {
            sh.sleepSeconds(io, 2);
            continue;
        };

        const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (posix.errno(rc) != .SUCCESS) {
            sh.sleepSeconds(io, 2);
            continue;
        }
        const fd: posix.fd_t = @intCast(rc);

        var addr: sockaddr_un = mem.zeroes(sockaddr_un);
        addr.family = posix.AF.UNIX;
        @memcpy(addr.path[0..sock_path.len], sock_path);
        addr.path[sock_path.len] = 0;

        if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) {
            _ = posix.system.close(fd);
            sh.sleepSeconds(io, 2);
            continue;
        }

        this.event_sock_fd.store(fd, .seq_cst);
        defer this.event_sock_fd.store(-1, .seq_cst);

        var read_buf: [1024]u8 = undefined;
        while (this.running.load(.seq_cst)) {
            const bytes_read = posix.read(fd, &read_buf) catch break;
            if (bytes_read == 0) break;
            if (!this.running.load(.seq_cst)) break;

            const chunk = read_buf[0..bytes_read];
            if (mem.find(u8, chunk, "workspace>>")) |idx| {
                const rest = chunk[idx + "workspace>>".len ..];
                var num_len: usize = 0;
                while (num_len < rest.len and (rest[num_len] >= '0' and rest[num_len] <= '9')) : (num_len += 1) {}
                if (num_len > 0) {
                    if (fmt.parseInt(i32, rest[0..num_len], 10)) |new_ws| {
                        this.active_id = new_ws;
                        _ = gtk.g_idle_add(@ptrCast(&onDirectActiveChanged), this);
                        continue;
                    } else |_| {}
                }
            }

            if (mem.find(u8, chunk, "workspace>>") != null or
                mem.find(u8, chunk, "focusedmon>>") != null or
                mem.find(u8, chunk, "createworkspace>>") != null or
                mem.find(u8, chunk, "destroyworkspace>>") != null)
            {
                _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), this);
            }
        }

        _ = posix.system.close(fd);
        sh.sleepSeconds(io, 1);
    }
}

fn swayWorker(this: *WorkspacesModule) void {
    const io = this.io;
    while (this.running.load(.seq_cst)) {
        const sock_path = env.get("SWAYSOCK") orelse env.get("I3SOCK") orelse {
            sh.sleepSeconds(io, 2);
            continue;
        };

        const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (posix.errno(rc) != .SUCCESS) {
            sh.sleepSeconds(io, 2);
            continue;
        }
        const fd: posix.fd_t = @intCast(rc);

        var addr: sockaddr_un = mem.zeroes(sockaddr_un);
        addr.family = posix.AF.UNIX;
        if (sock_path.len >= addr.path.len) {
            _ = posix.system.close(fd);
            sh.sleepSeconds(io, 2);
            continue;
        }
        @memcpy(addr.path[0..sock_path.len], sock_path);
        addr.path[sock_path.len] = 0;

        if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) {
            _ = posix.system.close(fd);
            sh.sleepSeconds(io, 2);
            continue;
        }

        this.event_sock_fd.store(fd, .seq_cst);
        defer this.event_sock_fd.store(-1, .seq_cst);

        const subscribe_cmd = "i3-ipc\x0f\x00\x00\x00\x02\x00\x00\x00[\"workspace\"]";
        _ = posix.system.write(fd, subscribe_cmd.ptr, subscribe_cmd.len);

        var read_buf: [1024]u8 = undefined;
        while (this.running.load(.seq_cst)) {
            const bytes_read = posix.read(fd, &read_buf) catch break;
            if (bytes_read == 0) break;
            if (!this.running.load(.seq_cst)) break;

            _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), this);
        }

        _ = posix.system.close(fd);
        sh.sleepSeconds(io, 1);
    }
}

fn niriWorker(this: *WorkspacesModule) void {
    const io = this.io;
    while (this.running.load(.seq_cst)) {
        var child = sh.spawnStream(io, "niri msg --json event-stream 2>/dev/null") catch {
            sh.sleepSeconds(io, 1);
            continue;
        };
        defer if (child.id != null) {
            child.kill(io);
        };

        var io_buf: [2048]u8 = undefined;
        var f_reader = child.stdout.?.reader(io, &io_buf);

        while (this.running.load(.seq_cst)) {
            _ = f_reader.interface.takeDelimiterInclusive('\n') catch break;
            _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), this);
        }

        sh.sleepSeconds(io, 1);
    }
}
