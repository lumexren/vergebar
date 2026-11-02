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
const Thread = std.Thread;
const atomic = std.atomic;
const debug = std.debug;
const json = std.json;
const posix = std.posix;
const gtk = @import("gtk");
const ModuleSettings = @import("utils").Config.ModuleSettings;

const Context = @import("utils").Context;

const sockaddr_un = extern struct {
    sun_family: u16,
    sun_path: [108]u8,
};

pub const Compositor = enum {
    kde,
    hyprland,
    sway,
    niri,
    river,
    dwl,
    wayfire,
    mango,
    generic,

    pub fn name(self: Compositor) []const u8 {
        return switch (self) {
            .kde => "KDE Plasma (KWin)",
            .hyprland => "Hyprland",
            .sway => "Sway / i3",
            .niri => "Niri",
            .river => "River",
            .dwl => "DWL",
            .wayfire => "Wayfire",
            .mango => "Mango",
            .generic => "Generic Wayland",
        };
    }
};

pub const WorkspaceButton = struct {
    button: ?*gtk.GtkWidget,
    label: ?*gtk.GtkWidget,
    id: i32,
};

pub const WorkspacesModule = struct {
    allocator: Allocator,
    box: ?*gtk.GtkWidget,
    buttons: ArrayList(WorkspaceButton),
    active_id: i32 = 1,
    compositor: Compositor,
    timer_id: u32 = 0,
    dbus_conn: ?*gtk.GDBusConnection = null,
    kwin_sub_id: c_uint = 0,
    event_thread: ?Thread = null,
    running: atomic.Value(bool) = .init(true),

    pub fn create(allocator: Allocator, name_hint: []const u8, settings: ModuleSettings) !*WorkspacesModule {
        _ = settings;
        const comp = detectCompositor(name_hint);
        debug.print("Workspaces module initialized with compositor: {s}\n", .{comp.name()});

        const self = try allocator.create(WorkspacesModule);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 2),
            .buttons = .empty,
            .compositor = comp,
        };

        if (self.box) |b| {
            gtk.gtk_widget_set_name(b, "workspaces");
            gtk.gtk_widget_add_css_class(b, "workspaces");
        }

        if (self.compositor == .kde) {
            var err: ?*anyopaque = null;
            self.dbus_conn = gtk.g_bus_get_sync(@backingInt(gtk.GBusType.session), null, &err);
            if (self.dbus_conn) |conn| {
                self.kwin_sub_id = gtk.g_dbus_connection_signal_subscribe(
                    conn,
                    "org.kde.KWin",
                    "org.kde.KWin.VirtualDesktopManager",
                    null,
                    "/VirtualDesktopManager",
                    null,
                    0,
                    @ptrCast(&onKdeSignal),
                    self,
                    null,
                );
            }
        }

        self.rebuildButtons();
        self.update();

        switch (self.compositor) {
            .hyprland => {
                self.event_thread = Thread.spawn(.{}, hyprlandWorker, .{self}) catch null;
            },
            .sway => {
                self.event_thread = Thread.spawn(.{}, swayWorker, .{self}) catch null;
            },
            .niri => {
                self.event_thread = Thread.spawn(.{}, niriWorker, .{self}) catch null;
            },
            .kde, .river, .dwl, .wayfire, .mango, .generic => {},
        }

        self.timer_id = gtk.g_timeout_add_seconds(2, @ptrCast(&onHeartbeat), self);

        return self;
    }

    pub fn deinit(self: *WorkspacesModule) void {
        self.running.store(false, .seq_cst);

        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }

        if (self.compositor == .kde) {
            if (self.dbus_conn) |conn| {
                if (self.kwin_sub_id != 0) {
                    gtk.g_dbus_connection_signal_unsubscribe(conn, self.kwin_sub_id);
                    self.kwin_sub_id = 0;
                }
            }
        }

        if (self.event_thread) |thread| {
            thread.detach();
        }

        self.clearButtons();
        self.buttons.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn clearButtons(self: *WorkspacesModule) void {
        if (self.box) |b| {
            for (self.buttons.items) |ws| {
                if (ws.button) |btn| {
                    gtk.gtk_box_remove(@ptrCast(b), btn);
                }
            }
        }
        self.buttons.clearRetainingCapacity();
    }

    pub fn rebuildButtons(self: *WorkspacesModule) void {
        self.clearButtons();
        const count = self.getWorkspaceCount();

        var i: i32 = 1;
        while (i <= count) : (i += 1) {
            const btn = gtk.gtk_button_new();
            gtk.gtk_button_set_has_frame(btn, 0);

            var id_buf: [16]u8 = undefined;
            const id_str = mem.print(&id_buf, "{d}", .{i}) catch "1";
            id_buf[id_str.len] = 0;
            const lbl = gtk.gtk_label_new(id_buf[0..id_str.len :0]);
            gtk.gtk_button_set_child(btn, lbl);

            gtk.gtk_widget_add_css_class(btn, "workspace-button");
            if (self.box) |b| {
                gtk.gtk_box_append(@ptrCast(b), btn);
            }

            const userdata = @as(usize, @intCast(i)) | (@as(usize, @backingInt(self.compositor)) << 32);

            _ = gtk.g_signal_connect_data(
                btn,
                "clicked",
                @ptrCast(&onWorkspaceClicked),
                @ptrFromInt(userdata),
                null,
                0,
            );

            self.buttons.append(self.allocator, .{
                .button = btn,
                .label = lbl,
                .id = i,
            }) catch break;
        }
    }

    fn getWorkspaceCount(self: *WorkspacesModule) i32 {
        if (self.compositor == .kde) {
            if (self.dbus_conn) |conn| {
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
                            if (count >= 1) return @intCast(@max(count, 2));
                        }
                    }
                }
            }
        }
        return 5;
    }

    pub fn update(self: *WorkspacesModule) void {
        var active_id: i32 = self.active_id;

        switch (self.compositor) {
            .kde => {
                if (self.dbus_conn) |conn| {
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
                if (Context.runShellAlloc(self.allocator, "hyprctl activeworkspace -j 2>/dev/null")) |out| {
                    defer self.allocator.free(out);
                    if (json.parseFromSlice(json.Value, self.allocator, out, .{})) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            if (parsed.value.object.get("id")) |id_val| {
                                if (id_val == .integer) {
                                    active_id = @intCast(id_val.integer);
                                }
                            }
                        }
                    } else |_| {}
                } else |_| {}
            },
            .sway => {
                if (Context.runShellAlloc(self.allocator, "swaymsg -t get_workspaces 2>/dev/null")) |out| {
                    defer self.allocator.free(out);
                    if (json.parseFromSlice(json.Value, self.allocator, out, .{})) |parsed| {
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
                } else |_| {}
            },
            .niri => {
                if (Context.runShellAlloc(self.allocator, "niri msg --json workspaces 2>/dev/null")) |out| {
                    defer self.allocator.free(out);
                    if (json.parseFromSlice(json.Value, self.allocator, out, .{})) |parsed| {
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
                const len = Context.runShellBuf("riverctl get-focused-tags 2>/dev/null", &buf);
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
                const len = Context.runShellBuf("dwl-msg get_tags 2>/dev/null", &buf);
                if (len > 0) {
                    if (fmt.parseInt(i32, mem.trim(u8, buf[0..len], " \r\n\t"), 10)) |t| {
                        active_id = t;
                    } else |_| {}
                }
            },
            .wayfire => {
                var buf: [32]u8 = undefined;
                const len = Context.runShellBuf("wayfire-msg get_active_workspace 2>/dev/null", &buf);
                if (len > 0) {
                    if (fmt.parseInt(i32, mem.trim(u8, buf[0..len], " \r\n\t"), 10)) |ws| {
                        active_id = ws;
                    } else |_| {}
                }
            },
            .mango => {
                var buf: [32]u8 = undefined;
                const len = Context.runShellBuf("mangoc get-active-workspace 2>/dev/null", &buf);
                if (len > 0) {
                    if (fmt.parseInt(i32, mem.trim(u8, buf[0..len], " \r\n\t"), 10)) |ws| {
                        active_id = ws;
                    } else |_| {}
                }
            },
            .generic => {},
        }

        self.active_id = active_id;

        for (self.buttons.items) |ws| {
            if (ws.button) |btn| {
                if (ws.id == self.active_id) {
                    gtk.gtk_widget_add_css_class(btn, "active");
                    gtk.gtk_widget_add_css_class(btn, "focused");
                } else {
                    gtk.gtk_widget_remove_css_class(btn, "active");
                    gtk.gtk_widget_remove_css_class(btn, "focused");
                }
            }
        }
    }
};

fn onHeartbeat(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *WorkspacesModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}

fn onEventTrigger(user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const self: *WorkspacesModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
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
    const self: *WorkspacesModule = @ptrCast(@alignCast(user_data orelse return));
    const sig = if (signal_name) |s| mem.span(s) else "";

    if (mem.eql(u8, sig, "countChanged") or mem.eql(u8, sig, "desktopCreated") or mem.eql(u8, sig, "desktopRemoved")) {
        self.rebuildButtons();
    }
    self.update();
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
            const str = mem.print(&cmd_buf, "hyprctl dispatch workspace {d}", .{ws_id}) catch return;
            cmd_buf[str.len] = 0;
            cmd = cmd_buf[0..str.len :0];
        },
        .sway => {
            const str = mem.print(&cmd_buf, "swaymsg workspace {d}", .{ws_id}) catch return;
            cmd_buf[str.len] = 0;
            cmd = cmd_buf[0..str.len :0];
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

fn hyprlandWorker(self: *WorkspacesModule) void {
    while (self.running.load(.seq_cst)) {
        const xdg = Context.getEnv("XDG_RUNTIME_DIR") orelse "/run/user/1000";
        const sig = Context.getEnv("HYPRLAND_INSTANCE_SIGNATURE") orelse {
            Context.sleepSeconds(2);
            continue;
        };

        var path_buf: [108]u8 = undefined;
        const sock_path = mem.print(&path_buf, "{s}/hypr/{s}/.socket2.sock", .{ xdg, sig }) catch {
            Context.sleepSeconds(2);
            continue;
        };

        const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (posix.errno(rc) != .SUCCESS) {
            Context.sleepSeconds(2);
            continue;
        }
        const fd: posix.fd_t = @intCast(rc);

        var addr: sockaddr_un = mem.zeroes(sockaddr_un);
        addr.sun_family = 1;
        @memcpy(addr.sun_path[0..sock_path.len], sock_path);
        addr.sun_path[sock_path.len] = 0;

        if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) {
            _ = posix.system.close(fd);
            Context.sleepSeconds(2);
            continue;
        }

        var read_buf: [1024]u8 = undefined;
        while (self.running.load(.seq_cst)) {
            const bytes_read = posix.read(fd, &read_buf) catch break;
            if (bytes_read == 0) break;

            const chunk = read_buf[0..bytes_read];
            if (mem.find(u8, chunk, "workspace>>") != null or
                mem.find(u8, chunk, "focusedmon>>") != null or
                mem.find(u8, chunk, "createworkspace>>") != null or
                mem.find(u8, chunk, "destroyworkspace>>") != null)
            {
                _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), self);
            }
        }

        _ = posix.system.close(fd);
        Context.sleepSeconds(1);
    }
}

fn swayWorker(self: *WorkspacesModule) void {
    while (self.running.load(.seq_cst)) {
        const sock_path = Context.getEnv("SWAYSOCK") orelse Context.getEnv("I3SOCK") orelse {
            Context.sleepSeconds(2);
            continue;
        };

        const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (posix.errno(rc) != .SUCCESS) {
            Context.sleepSeconds(2);
            continue;
        }
        const fd: posix.fd_t = @intCast(rc);

        var addr: sockaddr_un = mem.zeroes(sockaddr_un);
        addr.sun_family = 1;
        if (sock_path.len >= addr.sun_path.len) {
            _ = posix.system.close(fd);
            Context.sleepSeconds(2);
            continue;
        }
        @memcpy(addr.sun_path[0..sock_path.len], sock_path);
        addr.sun_path[sock_path.len] = 0;

        if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) {
            _ = posix.system.close(fd);
            Context.sleepSeconds(2);
            continue;
        }

        const subscribe_cmd = "i3-ipc\x0f\x00\x00\x00\x02\x00\x00\x00[\"workspace\"]";
        _ = posix.system.write(fd, subscribe_cmd.ptr, subscribe_cmd.len);

        var read_buf: [1024]u8 = undefined;
        while (self.running.load(.seq_cst)) {
            const bytes_read = posix.read(fd, &read_buf) catch break;
            if (bytes_read == 0) break;

            _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), self);
        }

        _ = posix.system.close(fd);
        Context.sleepSeconds(1);
    }
}

fn niriWorker(self: *WorkspacesModule) void {
    const ctx = Context.get() orelse return;
    while (self.running.load(.seq_cst)) {
        var child = Context.spawnShellStream("niri msg --json event-stream 2>/dev/null") catch {
            Context.sleepSeconds(1);
            continue;
        };
        defer if (child.id != null) {
            child.kill(ctx.io);
        };

        var io_buf: [2048]u8 = undefined;
        var f_reader = child.stdout.?.reader(ctx.io, &io_buf);

        while (self.running.load(.seq_cst)) {
            _ = f_reader.interface.takeDelimiterInclusive('\n') catch break;
            _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), self);
        }

        Context.sleepSeconds(1);
    }
}

fn detectCompositor(name_hint: []const u8) Compositor {
    if (Context.getEnv("HYPRLAND_INSTANCE_SIGNATURE") != null) return .hyprland;
    if (Context.getEnv("SWAYSOCK") != null or Context.getEnv("I3SOCK") != null) return .sway;
    if (Context.getEnv("NIRI_SOCKET") != null) return .niri;
    if (Context.getEnv("RIVER_SOCKET") != null) return .river;

    if (checkEnvContains("XDG_CURRENT_DESKTOP", "KDE") or
        checkEnvContains("XDG_SESSION_DESKTOP", "KDE") or
        Context.getEnv("KDE_FULL_SESSION") != null)
    {
        return .kde;
    }

    var buf: [64]u8 = undefined;
    const len = Context.runShellBuf("busctl --user call org.kde.KWin /KWin org.kde.KWin currentDesktop 2>/dev/null", &buf);
    if (len > 0) {
        if (mem.startsWith(u8, mem.trim(u8, buf[0..len], " \r\n\t"), "i ")) {
            return .kde;
        }
    }

    if (mem.startsWith(u8, name_hint, "hyprland")) return .hyprland;
    if (mem.startsWith(u8, name_hint, "sway")) return .sway;
    if (mem.startsWith(u8, name_hint, "niri")) return .niri;
    if (mem.startsWith(u8, name_hint, "kde") or mem.startsWith(u8, name_hint, "kwin")) return .kde;
    if (mem.startsWith(u8, name_hint, "river")) return .river;
    if (mem.startsWith(u8, name_hint, "dwl")) return .dwl;
    if (mem.startsWith(u8, name_hint, "wayfire")) return .wayfire;
    if (mem.startsWith(u8, name_hint, "mango")) return .mango;

    return .generic;
}

fn checkEnvContains(var_name: []const u8, needle: []const u8) bool {
    const val = Context.getEnv(var_name) orelse return false;
    return mem.find(u8, val, needle) != null;
}
