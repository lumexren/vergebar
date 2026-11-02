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
const json = std.json;
const gtk = @import("gtk");
const ModuleSettings = @import("utils").Config.ModuleSettings;

const Context = @import("utils").Context;

pub const TaskItem = struct {
    button: ?*gtk.GtkWidget,
    label: ?*gtk.GtkWidget,
    image: ?*gtk.GtkWidget,
    id_str: []const u8,
};

pub const TaskbarModule = struct {
    allocator: Allocator,
    box: ?*gtk.GtkWidget,
    tasks: ArrayList(TaskItem),
    icon_size: i32,
    max_title_len: usize,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name_hint: []const u8, settings: ModuleSettings) !*TaskbarModule {
        _ = name_hint;
        const self = try allocator.create(TaskbarModule);
        errdefer allocator.destroy(self);

        const icon_size = @as(i32, @intCast(settings.getInt("icon-size") orelse 16));
        const max_title = @as(usize, @intCast(settings.getInt("max-length") orelse 20));

        const main_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 4);
        if (main_box) |b| {
            gtk.gtk_widget_set_name(b, "taskbar");
            gtk.gtk_widget_add_css_class(b, "taskbar");
            gtk.gtk_widget_add_css_class(b, "wlr-taskbar");
        }

        self.* = .{
            .allocator = allocator,
            .box = main_box,
            .tasks = .empty,
            .icon_size = icon_size,
            .max_title_len = max_title,
        };

        self.update();
        self.timer_id = gtk.g_timeout_add_seconds(1, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *TaskbarModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.clearTasks();
        self.tasks.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn clearTasks(self: *TaskbarModule) void {
        if (self.box) |b| {
            for (self.tasks.items) |t| {
                if (t.button) |btn| gtk.gtk_box_remove(@ptrCast(b), btn);
                self.allocator.free(t.id_str);
            }
        }
        self.tasks.clearRetainingCapacity();
    }

    pub fn update(self: *TaskbarModule) void {
        const clients_out = Context.runShellAlloc(self.allocator, "hyprctl clients -j 2>/dev/null") catch return;
        defer self.allocator.free(clients_out);

        if (json.parseFromSlice(json.Value, self.allocator, clients_out, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .array) {
                self.clearTasks();
                for (parsed.value.array.items) |item| {
                    if (item == .object) {
                        const obj = item.object;
                        const title = if (obj.get("title")) |t| (if (t == .string) t.string else "") else "";
                        const class_name = if (obj.get("class")) |c| (if (c == .string) c.string else "") else "";
                        const addr = if (obj.get("address")) |a| (if (a == .string) a.string else "") else "";

                        if (title.len == 0 and class_name.len == 0) continue;

                        self.addTaskItem(title, class_name, addr);
                    }
                }
                return;
            }
        } else |_| {}
    }

    fn addTaskItem(self: *TaskbarModule, title: []const u8, class_name: []const u8, addr: []const u8) void {
        const btn = gtk.gtk_button_new();
        gtk.gtk_button_set_has_frame(btn, 0);
        gtk.gtk_widget_add_css_class(btn, "task-item");

        const inner_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 4);

        const img = gtk.gtk_image_new();
        gtk.gtk_image_set_pixel_size(@ptrCast(img), self.icon_size);
        var icon_z: [128]u8 = undefined;
        const icon_slice = if (class_name.len > 0) class_name else "application-x-executable";
        const icon_len = @min(icon_slice.len, icon_z.len - 1);
        @memcpy(icon_z[0..icon_len], icon_slice[0..icon_len]);
        icon_z[icon_len] = 0;
        gtk.gtk_image_set_from_icon_name(@ptrCast(img), @ptrCast(&icon_z));
        gtk.gtk_box_append(@ptrCast(inner_box), img);

        const display_title = if (title.len > self.max_title_len)
            title[0..self.max_title_len]
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

        if (self.box) |b| {
            gtk.gtk_box_append(@ptrCast(b), btn);
        }

        const id_owned = self.allocator.dupe(u8, addr) catch return;

        var tt_z: [256]u8 = undefined;
        const tt_len = @min(title.len, tt_z.len - 1);
        @memcpy(tt_z[0..tt_len], title[0..tt_len]);
        tt_z[tt_len] = 0;
        gtk.gtk_widget_set_tooltip_text(btn, @ptrCast(&tt_z));

        _ = gtk.g_signal_connect_data(
            btn,
            "clicked",
            @ptrCast(&onTaskClicked),
            @ptrCast(@alignCast(@constCast(id_owned.ptr))),
            null,
            0,
        );

        self.tasks.append(self.allocator, .{
            .button = btn,
            .label = lbl,
            .image = img,
            .id_str = id_owned,
        }) catch {};
    }
};

fn onTaskClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const addr_ptr: [*:0]const u8 = @ptrCast(user_data orelse return);
    var buf: [128]u8 = undefined;
    const cmd = mem.print(&buf, "hyprctl dispatch focuswindow address:{s}\x00", .{mem.span(addr_ptr)}) catch return;
    _ = gtk.g_spawn_command_line_async(@ptrCast(cmd.ptr), null);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *TaskbarModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
