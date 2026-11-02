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
const Thread = std.Thread;
const atomic = std.atomic;
const json = std.json;
const posix = std.posix;
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const workspaces = @import("workspaces.zig");
const Compositor = workspaces.Compositor;

const Context = @import("utils").Context;

const sockaddr_un = extern struct {
    sun_family: u16,
    sun_path: [108]u8,
};

pub const WindowModule = struct {
    base: *BaseModule,
    format: []const u8,
    max_length: usize,
    compositor: Compositor,
    timer_id: u32 = 0,
    event_thread: ?Thread = null,
    running: atomic.Value(bool) = .init(true),

    title: []const u8 = "",
    class: []const u8 = "",

    pub fn create(allocator: Allocator, name_hint: []const u8, settings: ModuleSettings) !*WindowModule {
        const self = try allocator.create(WindowModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        const base_mod = try BaseModule.init(allocator, "window", "window", on_click, on_click_middle, on_click_right);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "{title}";
        const max_len_i = settings.getInt("max-length") orelse 0;

        self.* = .{
            .base = base_mod,
            .format = format_str,
            .max_length = if (max_len_i > 0) @intCast(max_len_i) else 0,
            .compositor = detectCompositor(name_hint),
            .running = .init(true),
            .title = "",
            .class = "",
            .timer_id = 0,
            .event_thread = null,
        };

        self.update();

        switch (self.compositor) {
            .hyprland => {
                self.event_thread = Thread.spawn(.{}, hyprlandWindowWorker, .{self}) catch null;
            },
            .sway => {
                self.event_thread = Thread.spawn(.{}, swayWindowWorker, .{self}) catch null;
            },
            .niri => {
                self.event_thread = Thread.spawn(.{}, niriWindowWorker, .{self}) catch null;
            },
            .kde, .river, .dwl, .wayfire, .mango, .generic => {},
        }

        self.timer_id = gtk.g_timeout_add_seconds(1, @ptrCast(&onHeartbeat), self);

        return self;
    }

    pub fn deinit(self: *WindowModule) void {
        self.running.store(false, .seq_cst);
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        if (self.event_thread) |thread| {
            thread.detach();
        }
        if (self.title.len > 0) self.base.allocator.free(self.title);
        if (self.class.len > 0) self.base.allocator.free(self.class);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn update(self: *WindowModule) void {
        var new_title: ?[]const u8 = null;
        var new_class: ?[]const u8 = null;

        switch (self.compositor) {
            .hyprland => {
                if (Context.runShellAlloc(self.base.allocator, "hyprctl activewindow -j 2>/dev/null")) |out| {
                    defer self.base.allocator.free(out);
                    if (json.parseFromSlice(json.Value, self.base.allocator, out, .{})) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            if (parsed.value.object.get("title")) |t| {
                                if (t == .string and t.string.len > 0) {
                                    new_title = self.base.allocator.dupe(u8, t.string) catch null;
                                }
                            }
                            if (parsed.value.object.get("class")) |c| {
                                if (c == .string and c.string.len > 0) {
                                    new_class = self.base.allocator.dupe(u8, c.string) catch null;
                                }
                            }
                        }
                    } else |_| {}
                } else |_| {}
            },
            .sway => {
                if (Context.runShellAlloc(self.base.allocator, "swaymsg -t get_tree 2>/dev/null")) |out| {
                    defer self.base.allocator.free(out);
                    if (json.parseFromSlice(json.Value, self.base.allocator, out, .{})) |parsed| {
                        defer parsed.deinit();
                        if (findFocusedNode(parsed.value)) |focused| {
                            if (focused.get("name")) |n| {
                                if (n == .string and n.string.len > 0) {
                                    new_title = self.base.allocator.dupe(u8, n.string) catch null;
                                }
                            }
                            if (focused.get("app_id")) |a| {
                                if (a == .string and a.string.len > 0) {
                                    new_class = self.base.allocator.dupe(u8, a.string) catch null;
                                }
                            }
                        }
                    } else |_| {}
                } else |_| {}
            },
            .niri => {
                if (Context.runShellAlloc(self.base.allocator, "niri msg --json focused-window 2>/dev/null")) |out| {
                    defer self.base.allocator.free(out);
                    if (json.parseFromSlice(json.Value, self.base.allocator, out, .{})) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            if (parsed.value.object.get("title")) |t| {
                                if (t == .string and t.string.len > 0) {
                                    new_title = self.base.allocator.dupe(u8, t.string) catch null;
                                }
                            }
                            if (parsed.value.object.get("app_id")) |a| {
                                if (a == .string and a.string.len > 0) {
                                    new_class = self.base.allocator.dupe(u8, a.string) catch null;
                                }
                            }
                        }
                    } else |_| {}
                } else |_| {}
            },
            .river => {
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("riverctl get-focused-view 2>/dev/null", &buf);
                if (len > 0) new_title = self.base.allocator.dupe(u8, mem.trim(u8, buf[0..len], " \r\n\t")) catch null;
            },
            .dwl => {
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("dwl-msg get_active_title 2>/dev/null", &buf);
                if (len > 0) new_title = self.base.allocator.dupe(u8, mem.trim(u8, buf[0..len], " \r\n\t")) catch null;
            },
            .wayfire => {
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("wayfire-msg get_active_window 2>/dev/null", &buf);
                if (len > 0) new_title = self.base.allocator.dupe(u8, mem.trim(u8, buf[0..len], " \r\n\t")) catch null;
            },
            .mango => {
                var buf: [256]u8 = undefined;
                const len = Context.runShellBuf("mangoc get-active-window 2>/dev/null", &buf);
                if (len > 0) new_title = self.base.allocator.dupe(u8, mem.trim(u8, buf[0..len], " \r\n\t")) catch null;
            },
            .kde, .generic => {},
        }

        if (self.title.len > 0) self.base.allocator.free(self.title);
        if (self.class.len > 0) self.base.allocator.free(self.class);
        self.title = new_title orelse "";
        self.class = new_class orelse "";

        self.render();
    }

    fn render(self: *WindowModule) void {
        const is_empty = self.title.len == 0;

        if (is_empty) {
            gtk.gtk_widget_add_css_class(self.base.button, "empty");
            self.base.setText("");
            self.base.setTooltip("");
            return;
        }

        gtk.gtk_widget_remove_css_class(self.base.button, "empty");

        var buf1: [512]u8 = undefined;
        var buf2: [512]u8 = undefined;

        const title_val = if (self.title.len > 0) self.title else self.class;

        var count = mem.replace(u8, self.format, "{title}", title_val, &buf1);
        var current: []const u8 = buf1[0 .. self.format.len - count * 7 + count * title_val.len];

        count = mem.replace(u8, current, "{}", title_val, &buf2);
        current = buf2[0 .. current.len - count * 2 + count * title_val.len];

        count = mem.replace(u8, current, "{class}", self.class, &buf1);
        current = buf1[0 .. current.len - count * 7 + count * self.class.len];

        if (self.max_length > 0 and current.len > self.max_length) {
            const cut_len = @min(current.len, self.max_length);
            var truncated: [512]u8 = undefined;
            const t_str = mem.print(&truncated, "{s}...", .{current[0..cut_len]}) catch current;
            self.base.setText(t_str);
        } else {
            self.base.setText(current);
        }

        self.base.setTooltip(self.title);
    }
};

fn onHeartbeat(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *WindowModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}

fn onEventTrigger(user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const self: *WindowModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 0;
}

fn hyprlandWindowWorker(self: *WindowModule) void {
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
            if (mem.find(u8, chunk, "activewindow>>") != null or
                mem.find(u8, chunk, "activewindowv2>>") != null or
                mem.find(u8, chunk, "closewindow>>") != null or
                mem.find(u8, chunk, "workspace>>") != null)
            {
                _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), self);
            }
        }

        _ = posix.system.close(fd);
        Context.sleepSeconds(1);
    }
}

fn swayWindowWorker(self: *WindowModule) void {
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

        const subscribe_cmd = "i3-ipc\x0c\x00\x00\x00\x02\x00\x00\x00[\"window\"]";
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

fn niriWindowWorker(self: *WindowModule) void {
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

fn findFocusedNode(node: json.Value) ?json.ObjectMap {
    if (node != .object) return null;
    const obj = node.object;
    if (obj.get("focused")) |f| {
        if (f == .bool and f.bool) return obj;
    }
    if (obj.get("nodes")) |n| {
        if (n == .array) {
            for (n.array.items) |child| {
                if (findFocusedNode(child)) |res| return res;
            }
        }
    }
    if (obj.get("floating_nodes")) |fn_list| {
        if (fn_list == .array) {
            for (fn_list.array.items) |child| {
                if (findFocusedNode(child)) |res| return res;
            }
        }
    }
    return null;
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

    if (mem.startsWith(u8, name_hint, "hyprland")) return .hyprland;
    if (mem.startsWith(u8, name_hint, "sway")) return .sway;
    if (mem.startsWith(u8, name_hint, "niri")) return .niri;
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
