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

const TaskbarModule = @This();

pub const TaskItem = @import("TaskItem.zig");
pub const TaskClickContext = TaskItem.TaskClickContext;

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const json = std.json;
const posix = std.posix;
const gtk = @import("gtk");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const ipc = @import("utils").ipc;
const Compositor = @import("../workspaces/Compositor.zig").Compositor;

io: Io,
allocator: Allocator,
box: ?*gtk.GtkWidget,
tasks: ArrayList(TaskItem),
compositor: Compositor,
icon_size: i32,
max_title_len: usize,
timer_id: u32 = 0,
event_fd: posix.fd_t = -1,
event_source_id: c_uint = 0,

pub fn create(io: Io, allocator: Allocator, name_hint: []const u8, settings: ModuleSettings) !*TaskbarModule {
    const this = try allocator.create(TaskbarModule);
    errdefer allocator.destroy(this);

    const icon_size = @as(i32, @intCast(settings.getInt("icon-size") orelse 16));
    const max_title = @as(usize, @intCast(settings.getInt("max-length") orelse 20));
    const comp = Compositor.detect(name_hint);

    const main_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 4);
    if (main_box) |b| {
        gtk.gtk_widget_set_name(b, "taskbar");
        gtk.gtk_widget_add_css_class(b, "taskbar");
        gtk.gtk_widget_add_css_class(b, "wlr-taskbar");
    }

    this.* = .{
        .io = io,
        .allocator = allocator,
        .box = main_box,
        .tasks = .empty,
        .compositor = comp,
        .icon_size = icon_size,
        .max_title_len = max_title,
        .event_fd = -1,
        .event_source_id = 0,
    };

    this.update();

    switch (comp) {
        .hyprland => {
            if (ipc.connectHyprlandEventSocket()) |fd| {
                this.event_fd = fd;
                this.event_source_id = gtk.g_unix_fd_add(
                    fd,
                    gtk.G_IO_IN | gtk.G_IO_HUP | gtk.G_IO_ERR,
                    @ptrCast(&onEventFdReady),
                    this,
                );
            }
        },
        .sway => {
            if (ipc.connectSwayEventSocket("[\"window\"]")) |fd| {
                this.event_fd = fd;
                this.event_source_id = gtk.g_unix_fd_add(
                    fd,
                    gtk.G_IO_IN | gtk.G_IO_HUP | gtk.G_IO_ERR,
                    @ptrCast(&onEventFdReady),
                    this,
                );
            }
        },
        else => {},
    }

    this.timer_id = gtk.g_timeout_add_seconds(5, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *TaskbarModule) void {
    if (this.event_source_id != 0) {
        _ = gtk.g_source_remove(this.event_source_id);
        this.event_source_id = 0;
    }
    if (this.event_fd >= 0) {
        _ = posix.system.close(this.event_fd);
        this.event_fd = -1;
    }
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.clearTasks();
    this.tasks.deinit(this.allocator);
    this.allocator.destroy(this);
}

fn clearTasks(this: *TaskbarModule) void {
    if (this.box) |b| {
        for (this.tasks.items) |t| {
            if (t.button) |btn| gtk.gtk_box_remove(@ptrCast(b), btn);
            if (t.click_ctx) |ctx| this.allocator.destroy(ctx);
            this.allocator.free(t.id_str);
        }
    }
    this.tasks.clearRetainingCapacity();
}

pub fn update(this: *TaskbarModule) void {
    switch (this.compositor) {
        .hyprland => this.updateHyprland(),
        .sway => this.updateSway(),
        else => this.updateHyprland(),
    }
}

fn updateHyprland(this: *TaskbarModule) void {
    const clients_out = ipc.queryHyprlandSocket(this.allocator, "j/clients") orelse return;
    defer this.allocator.free(clients_out);

    if (json.parseFromSlice(json.Value, this.allocator, clients_out, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .array) {
            this.clearTasks();
            for (parsed.value.array.items) |item| {
                if (item == .object) {
                    const obj = item.object;
                    const title = if (obj.get("title")) |t| (if (t == .string) t.string else "") else "";
                    const class_name = if (obj.get("class")) |c| (if (c == .string) c.string else "") else "";
                    const addr = if (obj.get("address")) |a| (if (a == .string) a.string else "") else "";

                    if (title.len == 0 and class_name.len == 0) continue;

                    this.addTaskItem(title, class_name, addr);
                }
            }
        }
    } else |_| {}
}

fn updateSway(this: *TaskbarModule) void {
    const tree_out = ipc.querySwaySocket(this.allocator, 4, "") orelse return;
    defer this.allocator.free(tree_out);

    if (json.parseFromSlice(json.Value, this.allocator, tree_out, .{})) |parsed| {
        defer parsed.deinit();
        this.clearTasks();
        this.parseSwayNode(parsed.value);
    } else |_| {}
}

fn parseSwayNode(this: *TaskbarModule, node: json.Value) void {
    if (node != .object) return;
    const obj = node.object;

    if (obj.get("type")) |t_v| {
        if (t_v == .string and (mem.eql(u8, t_v.string, "con") or mem.eql(u8, t_v.string, "floating_con"))) {
            const name = if (obj.get("name")) |n| (if (n == .string) n.string else "") else "";
            const app_id = if (obj.get("app_id")) |a| (if (a == .string) a.string else "") else "";
            var id_buf: [32]u8 = undefined;
            const id_str = if (obj.get("id")) |id_v|
                (if (id_v == .integer) (mem.print(&id_buf, "{d}", .{id_v.integer}) catch "") else "")
            else
                "";

            if ((name.len > 0 or app_id.len > 0) and id_str.len > 0) {
                this.addTaskItem(name, app_id, id_str);
            }
        }
    }

    if (obj.get("nodes")) |nodes_v| {
        if (nodes_v == .array) {
            for (nodes_v.array.items) |child| this.parseSwayNode(child);
        }
    }
    if (obj.get("floating_nodes")) |fn_v| {
        if (fn_v == .array) {
            for (fn_v.array.items) |child| this.parseSwayNode(child);
        }
    }
}

fn addTaskItem(this: *TaskbarModule, title: []const u8, class_name: []const u8, addr: []const u8) void {
    const btn = gtk.gtk_button_new();
    gtk.gtk_button_set_has_frame(btn, 0);
    gtk.gtk_widget_add_css_class(btn, "task-item");

    const inner_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 4);

    const img = gtk.gtk_image_new();
    gtk.gtk_image_set_pixel_size(@ptrCast(img), this.icon_size);
    var icon_z: [128]u8 = undefined;
    const icon_slice = if (class_name.len > 0) class_name else "application-x-executable";
    const icon_len = @min(icon_slice.len, icon_z.len - 1);
    @memcpy(icon_z[0..icon_len], icon_slice[0..icon_len]);
    icon_z[icon_len] = 0;
    gtk.gtk_image_set_from_icon_name(@ptrCast(img), @ptrCast(&icon_z));
    gtk.gtk_box_append(@ptrCast(inner_box), img);

    const display_title = if (title.len > this.max_title_len)
        title[0..this.max_title_len]
    else if (title.len > 0)
        title
    else
        class_name;

    var text_z: [128]u8 = undefined;
    const text_len = @min(display_title.len, text_z.len - 1);
    @memcpy(text_z[0..text_len], display_title[0..text_len]);
    text_z[text_len] = 0;
    const lbl = gtk.gtk_label_new(@ptrCast(&text_z));
    gtk.gtk_box_append(@ptrCast(inner_box), lbl);

    gtk.gtk_button_set_child(btn, inner_box);

    if (this.box) |b| {
        gtk.gtk_box_append(@ptrCast(b), btn);
    }

    const id_owned = this.allocator.dupe(u8, addr) catch return;

    var tt_z: [256]u8 = undefined;
    const tt_len = @min(title.len, tt_z.len - 1);
    @memcpy(tt_z[0..tt_len], title[0..tt_len]);
    tt_z[tt_len] = 0;
    gtk.gtk_widget_set_tooltip_text(btn, @ptrCast(&tt_z));

    const click_ctx = this.allocator.create(TaskClickContext) catch return;
    click_ctx.* = .{
        .compositor = this.compositor,
        .id_str = id_owned,
        .allocator = this.allocator,
    };

    _ = gtk.g_signal_connect_data(
        btn,
        "clicked",
        @ptrCast(&onTaskClicked),
        click_ctx,
        null,
        0,
    );

    this.tasks.append(this.allocator, .{
        .button = btn,
        .label = lbl,
        .image = img,
        .id_str = id_owned,
        .click_ctx = click_ctx,
    }) catch {};
}

fn onTaskClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const ctx: *TaskClickContext = @ptrCast(@alignCast(user_data orelse return));
    switch (ctx.compositor) {
        .hyprland => {
            var buf: [128]u8 = undefined;
            const cmd = mem.print(&buf, "dispatch focuswindow address:{s}", .{ctx.id_str}) catch return;
            if (ipc.queryHyprlandSocket(ctx.allocator, cmd)) |resp| {
                ctx.allocator.free(resp);
            } else {
                var spawn_buf: [160]u8 = undefined;
                const spawn_cmd = mem.printSentinel(&spawn_buf, "hyprctl dispatch focuswindow address:{s}", .{ctx.id_str}, 0) catch return;
                _ = gtk.g_spawn_command_line_async(@ptrCast(spawn_cmd.ptr), null);
            }
        },
        .sway => {
            var buf: [128]u8 = undefined;
            const cmd = mem.print(&buf, "[con_id={s}] focus", .{ctx.id_str}) catch return;
            if (ipc.querySwaySocket(ctx.allocator, 0, cmd)) |resp| {
                ctx.allocator.free(resp);
            } else {
                var spawn_buf: [160]u8 = undefined;
                const spawn_cmd = mem.printSentinel(&spawn_buf, "swaymsg '[con_id={s}] focus'", .{ctx.id_str}, 0) catch return;
                _ = gtk.g_spawn_command_line_async(@ptrCast(spawn_cmd.ptr), null);
            }
        },
        else => {},
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *TaskbarModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onEventFdReady(fd: c_int, condition: gtk.GIOCondition, user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const this: *TaskbarModule = @ptrCast(@alignCast(user_data orelse return 0));
    if ((condition & (gtk.G_IO_ERR | gtk.G_IO_HUP)) != 0) {
        return 0;
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = posix.system.read(fd, &buf, buf.len);
        if (rc <= 0) break;
    }

    this.update();
    return 1;
}
