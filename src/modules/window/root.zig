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

const WindowModule = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Thread = std.Thread;
const atomic = std.atomic;
const json = std.json;
const posix = std.posix;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const workspaces = @import("../workspaces/root.zig");
const Compositor = workspaces.Compositor;
const Template = @import("utils").Template;
const Replacer = @import("utils").Replacer;

const sh = @import("utils").sh;
const env = @import("utils").env;
const ipc = @import("utils").ipc;
const queryHyprlandSocket = ipc.queryHyprlandSocket;
const querySwaySocket = ipc.querySwaySocket;
const queryNiriSocket = ipc.queryNiriSocket;

const sockaddr_un = posix.sockaddr.un;

base: *BaseModule,
format: []const u8,
max_length: usize,
compositor: Compositor,
replacer: Replacer,
template_tooltip: ?Template = null,
timer_id: u32 = 0,
event_thread: ?Thread = null,
running: atomic.Value(bool) = .init(true),
event_sock_fd: atomic.Value(posix.fd_t) = .init(-1),

title: []const u8 = "",
class: []const u8 = "",

pub fn create(io: Io, allocator: Allocator, name_hint: []const u8, settings: ModuleSettings) !*WindowModule {
    const this = try allocator.create(WindowModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name_hint, "window", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getString("format") orelse "{title}";
    const max_len_i = settings.getInt("max-length") orelse 0;

    this.* = .{
        .base = base_mod,
        .format = format_str,
        .max_length = if (max_len_i > 0) @intCast(max_len_i) else 0,
        .compositor = Compositor.detect(name_hint),
        .replacer = .init(allocator),
        .template_tooltip = if (base_mod.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null,
        .running = .init(true),
        .title = "",
        .class = "",
        .timer_id = 0,
        .event_thread = null,
    };

    this.update();

    switch (this.compositor) {
        .hyprland => {
            this.event_thread = Thread.spawn(.{}, hyprlandWindowWorker, .{this}) catch null;
        },
        .sway => {
            this.event_thread = Thread.spawn(.{}, swayWindowWorker, .{this}) catch null;
        },
        .niri => {
            this.event_thread = Thread.spawn(.{}, niriWindowWorker, .{this}) catch null;
        },
        .kde, .river, .dwl, .wayfire, .mango, .generic => {},
    }

    this.timer_id = gtk.g_timeout_add_seconds(1, @ptrCast(&onHeartbeat), this);

    return this;
}

pub fn deinit(this: *WindowModule) void {
    const alloc = this.base.allocator;
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
    if (this.event_thread) |thread| {
        thread.join();
        this.event_thread = null;
    }
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    if (this.title.len > 0) alloc.free(this.title);
    if (this.class.len > 0) alloc.free(this.class);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *WindowModule) void {
    var new_title: ?[]const u8 = null;
    var new_class: ?[]const u8 = null;

    switch (this.compositor) {
        .hyprland => {
            const out_opt = queryHyprlandSocket(this.base.allocator, "j/activewindow") orelse
                (sh.runAlloc(this.base.io, this.base.allocator, "hyprctl activewindow -j 2>/dev/null") catch null);
            if (out_opt) |out| {
                defer this.base.allocator.free(out);
                if (json.parseFromSlice(json.Value, this.base.allocator, out, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("title")) |t| {
                            if (t == .string and t.string.len > 0) {
                                new_title = this.base.allocator.dupe(u8, t.string) catch null;
                            }
                        }
                        if (parsed.value.object.get("class")) |c| {
                            if (c == .string and c.string.len > 0) {
                                new_class = this.base.allocator.dupe(u8, c.string) catch null;
                            }
                        }
                    }
                } else |_| {}
            }
        },
        .sway => {
            const out_opt = querySwaySocket(this.base.allocator, 4, "") orelse
                (sh.runAlloc(this.base.io, this.base.allocator, "swaymsg -t get_tree 2>/dev/null") catch null);
            if (out_opt) |out| {
                defer this.base.allocator.free(out);
                if (json.parseFromSlice(json.Value, this.base.allocator, out, .{})) |parsed| {
                    defer parsed.deinit();
                    if (findFocusedNode(parsed.value)) |focused| {
                        if (focused.get("name")) |n| {
                            if (n == .string and n.string.len > 0) {
                                new_title = this.base.allocator.dupe(u8, n.string) catch null;
                            }
                        }
                        if (focused.get("app_id")) |a| {
                            if (a == .string and a.string.len > 0) {
                                new_class = this.base.allocator.dupe(u8, a.string) catch null;
                            }
                        }
                    }
                } else |_| {}
            }
        },
        .niri => {
            const out_opt = queryNiriSocket(this.base.allocator, "\"FocusedWindow\"\n") orelse
                (sh.runAlloc(this.base.io, this.base.allocator, "niri msg --json focused-window 2>/dev/null") catch null);
            if (out_opt) |out| {
                defer this.base.allocator.free(out);
                if (json.parseFromSlice(json.Value, this.base.allocator, out, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("title")) |t| {
                            if (t == .string and t.string.len > 0) {
                                new_title = this.base.allocator.dupe(u8, t.string) catch null;
                            }
                        }
                        if (parsed.value.object.get("app_id")) |a| {
                            if (a == .string and a.string.len > 0) {
                                new_class = this.base.allocator.dupe(u8, a.string) catch null;
                            }
                        }
                    }
                } else |_| {}
            }
        },
        .river => {
            var buf: [256]u8 = undefined;
            const len = sh.runBuf(this.base.io, "riverctl get-focused-view 2>/dev/null", &buf);
            if (len > 0) new_title = this.base.allocator.dupe(u8, mem.trim(u8, buf[0..len], " \r\n\t")) catch null;
        },
        .dwl => {
            var buf: [256]u8 = undefined;
            const len = sh.runBuf(this.base.io, "dwl-msg get_active_title 2>/dev/null", &buf);
            if (len > 0) new_title = this.base.allocator.dupe(u8, mem.trim(u8, buf[0..len], " \r\n\t")) catch null;
        },
        .wayfire => {
            var buf: [256]u8 = undefined;
            const len = sh.runBuf(this.base.io, "wayfire-msg get_active_window 2>/dev/null", &buf);
            if (len > 0) new_title = this.base.allocator.dupe(u8, mem.trim(u8, buf[0..len], " \r\n\t")) catch null;
        },
        .mango => {
            var buf: [256]u8 = undefined;
            const len = sh.runBuf(this.base.io, "mangoc get-active-window 2>/dev/null", &buf);
            if (len > 0) new_title = this.base.allocator.dupe(u8, mem.trim(u8, buf[0..len], " \r\n\t")) catch null;
        },
        .kde, .generic => {},
    }

    if (this.title.len > 0) this.base.allocator.free(this.title);
    if (this.class.len > 0) this.base.allocator.free(this.class);
    this.title = new_title orelse "";
    this.class = new_class orelse "";

    this.render();
}

fn render(this: *WindowModule) void {
    const is_empty = this.title.len == 0;

    if (is_empty) {
        gtk.gtk_widget_add_css_class(this.base.button, "empty");
        this.base.setText("");
        this.base.setTooltip("");
        return;
    }

    gtk.gtk_widget_remove_css_class(this.base.button, "empty");

    var buf1: [512]u8 = undefined;
    var buf2: [512]u8 = undefined;

    const title_val = if (this.title.len > 0) this.title else this.class;

    var count = mem.replace(u8, this.format, "{title}", title_val, &buf1);
    var current: []const u8 = buf1[0 .. this.format.len - count * 7 + count * title_val.len];

    count = mem.replace(u8, current, "{}", title_val, &buf2);
    current = buf2[0 .. current.len - count * 2 + count * title_val.len];

    count = mem.replace(u8, current, "{class}", this.class, &buf1);
    current = buf1[0 .. current.len - count * 7 + count * this.class.len];

    if (this.max_length > 0 and current.len > this.max_length) {
        const cut_len = @min(current.len, this.max_length);
        var truncated: [512]u8 = undefined;
        const t_str = mem.print(&truncated, "{s}...", .{current[0..cut_len]}) catch current;
        this.base.setText(t_str);
    } else {
        this.base.setText(current);
    }

    if (this.template_tooltip) |*tt_tmpl| {
        this.replacer.clear();
        this.replacer.addKey("title", this.title) catch {};
        this.replacer.addKey("class", this.class) catch {};
        var tt_buf: [512]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {
            this.base.setTooltip(this.title);
        }
    } else {
        this.base.setTooltip(this.title);
    }
}

fn onHeartbeat(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *WindowModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onEventTrigger(user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const this: *WindowModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 0;
}

fn hyprlandWindowWorker(this: *WindowModule) void {
    const io = this.base.io;
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

            const chunk = read_buf[0..bytes_read];
            if (mem.find(u8, chunk, "activewindow>>") != null or
                mem.find(u8, chunk, "activewindowv2>>") != null or
                mem.find(u8, chunk, "closewindow>>") != null or
                mem.find(u8, chunk, "workspace>>") != null)
            {
                _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), this);
            }
        }

        _ = posix.system.close(fd);
        sh.sleepSeconds(io, 1);
    }
}

fn swayWindowWorker(this: *WindowModule) void {
    const io = this.base.io;
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

        const subscribe_cmd = "i3-ipc\x0c\x00\x00\x00\x02\x00\x00\x00[\"window\"]";
        _ = posix.system.write(fd, subscribe_cmd.ptr, subscribe_cmd.len);

        var read_buf: [1024]u8 = undefined;
        while (this.running.load(.seq_cst)) {
            const bytes_read = posix.read(fd, &read_buf) catch break;
            if (bytes_read == 0) break;

            _ = gtk.g_idle_add(@ptrCast(&onEventTrigger), this);
        }

        _ = posix.system.close(fd);
        sh.sleepSeconds(io, 1);
    }
}

fn niriWindowWorker(this: *WindowModule) void {
    const io = this.base.io;
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
