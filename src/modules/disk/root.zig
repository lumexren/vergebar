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

const DiskModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const fmt = std.fmt;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;
const statvfs = @import("bindings").statvfs;

const MountClickContext = struct {
    path: [:0]const u8,
    allocator: Allocator,
    mod: *DiskModule,
};

base: *BaseModule,
path: []const u8,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,
popover: ?*gtk.GtkWidget = null,
mount_contexts: ArrayList(*MountClickContext),

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*DiskModule {
    const this = try allocator.create(DiskModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "disk", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {percentage_used}%");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.path = try allocator.dupe(u8, settings.getOr([]const u8, "path", "/"));
    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", ""));
    this.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 80.0);
    this.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 90.0);
    this.interval_sec = settings.getOr(u32, "interval", 10);
    this.popover = null;
    this.mount_contexts = .empty;

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *DiskModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    for (this.mount_contexts.items) |ctx| {
        this.base.allocator.free(ctx.path);
        this.base.allocator.destroy(ctx);
    }
    this.mount_contexts.deinit(this.base.allocator);

    const alloc = this.base.allocator;
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    alloc.free(this.path);
    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *DiskModule) void {
    var stat: statvfs.Statfs = undefined;
    var path_z: [256]u8 = undefined;
    const len = @min(this.path.len, path_z.len - 1);
    @memcpy(path_z[0..len], this.path[0..len]);
    path_z[len] = 0;

    if (statvfs.statfs(path_z[0..len :0], &stat) != 0) return;

    const bsize: u64 = if (stat.f_frsize > 0) @intCast(stat.f_frsize) else @intCast(stat.f_bsize);
    const total_bytes = stat.f_blocks * bsize;
    const free_bytes = stat.f_bavail * bsize;
    const used_bytes = total_bytes -| free_bytes;

    const total_gb = @as(f64, @floatFromInt(total_bytes)) / 1024.0 / 1024.0 / 1024.0;
    const free_gb = @as(f64, @floatFromInt(free_bytes)) / 1024.0 / 1024.0 / 1024.0;
    const used_gb = @as(f64, @floatFromInt(used_bytes)) / 1024.0 / 1024.0 / 1024.0;

    const used_pct = if (total_bytes > 0)
        (@as(f64, @floatFromInt(used_bytes)) / @as(f64, @floatFromInt(total_bytes))) * 100.0
    else
        0.0;
    const used_pct_int: i64 = @intFromFloat(@round(used_pct));

    this.replacer.clear();

    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKey("path", this.path) catch {};
    this.replacer.addKeyAny("percentage_used", used_pct_int) catch {};
    this.replacer.addKeyAny("percentage_free", 100 - used_pct_int) catch {};
    this.replacer.addKeyAny("free", free_gb) catch {};
    this.replacer.addKeyAny("used", used_gb) catch {};
    this.replacer.addKeyAny("total", total_gb) catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "{s}: {d:.1} GiB used / {d:.1} GiB total ({d:.1} GiB free)", .{
            this.path,
            used_gb,
            total_gb,
            free_gb,
        }) catch "Disk";
        this.base.setTooltip(tt);
    }

    const is_warning = used_pct >= this.warning_threshold and used_pct < this.critical_threshold;
    const is_critical = used_pct >= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(used_pct, false);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *DiskModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    _ = btn_num;
    const this: *DiskModule = @ptrCast(@alignCast(user_data orelse return false));
    this.toggleDiskPopover();
    return true;
}

pub fn toggleDiskPopover(this: *DiskModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    for (this.mount_contexts.items) |ctx| {
        this.base.allocator.free(ctx.path);
        this.base.allocator.destroy(ctx);
    }
    this.mount_contexts.clearRetainingCapacity();

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "disk-popover");

        const header = gtk.gtk_label_new("Mounted Filesystems");
        if (header) |h| {
            gtk.gtk_widget_add_css_class(h, "title");
            gtk.gtk_box_append(@ptrCast(b), h);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        const scroll = gtk.gtk_scrolled_window_new();
        if (scroll) |sc| {
            gtk.gtk_scrolled_window_set_max_content_height(sc, 350);
            gtk.gtk_scrolled_window_set_propagate_natural_height(sc, 1);

            const list_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8);
            if (list_box) |lb| {
                const mounts = sysinfo.disk.fetchMountedFilesystems(this.base.allocator) catch null;
                if (mounts) |ms| {
                    defer sysinfo.disk.freeMountedFilesystems(this.base.allocator, ms);

                    for (ms) |m| {
                        const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
                        if (row_box) |rb| {
                            const top_row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 6);
                            if (top_row) |tr| {
                                var path_buf: [128]u8 = undefined;
                                if (mem.printSentinel(&path_buf, "{s} ({s})", .{ m.mount_point, m.fs_type }, 0)) |path_str| {
                                    const path_lbl = gtk.gtk_label_new(path_str.ptr);
                                    if (path_lbl) |pl| {
                                        gtk.gtk_widget_add_css_class(pl, "subtitle");
                                        gtk.gtk_box_append(@ptrCast(tr), pl);
                                    }
                                } else |_| {}

                                const open_btn = gtk.gtk_button_new_with_label("󰉋 Open");
                                if (open_btn) |ob| {
                                    const ctx = this.base.allocator.create(MountClickContext) catch continue;
                                    ctx.* = .{
                                        .path = this.base.allocator.dupeSentinel(u8, m.mount_point, 0) catch {
                                            this.base.allocator.destroy(ctx);
                                            continue;
                                        },
                                        .allocator = this.base.allocator,
                                        .mod = this,
                                    };
                                    this.mount_contexts.append(this.base.allocator, ctx) catch {
                                        this.base.allocator.free(ctx.path);
                                        this.base.allocator.destroy(ctx);
                                        continue;
                                    };

                                    _ = gtk.g_signal_connect_data(ob, "clicked", @ptrCast(&onOpenMountClicked), ctx, null, 0);
                                    gtk.gtk_box_append(@ptrCast(tr), ob);
                                }

                                gtk.gtk_box_append(@ptrCast(rb), tr);
                            }

                            const used_gb = @as(f64, @floatFromInt(m.disk_info.used)) / 1024.0 / 1024.0 / 1024.0;
                            const total_gb = @as(f64, @floatFromInt(m.disk_info.total)) / 1024.0 / 1024.0 / 1024.0;
                            const free_gb = @as(f64, @floatFromInt(m.disk_info.free)) / 1024.0 / 1024.0 / 1024.0;
                            const fraction = if (m.disk_info.total > 0)
                                @as(f64, @floatFromInt(m.disk_info.used)) / @as(f64, @floatFromInt(m.disk_info.total))
                            else
                                0.0;

                            const pbar = gtk.gtk_progress_bar_new();
                            if (pbar) |pb| {
                                gtk.gtk_progress_bar_set_fraction(@ptrCast(pb), fraction);
                                gtk.gtk_box_append(@ptrCast(rb), pb);
                            }

                            var stat_buf: [128]u8 = undefined;
                            const stat_str = mem.printSentinel(&stat_buf, "{d:.1} GiB used / {d:.1} GiB total ({d:.1} GiB free, {d}%)", .{
                                used_gb,
                                total_gb,
                                free_gb,
                                m.disk_info.percentage_used,
                            }, 0) catch "";
                            if (stat_str.len > 0) {
                                const stat_lbl = gtk.gtk_label_new(stat_str.ptr);
                                if (stat_lbl) |sl| gtk.gtk_box_append(@ptrCast(rb), sl);
                            }

                            gtk.gtk_box_append(@ptrCast(lb), rb);
                        }
                    }
                }

                gtk.gtk_scrolled_window_set_child(sc, lb);
            }

            gtk.gtk_box_append(@ptrCast(b), sc);
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onOpenMountClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const ctx: *MountClickContext = @ptrCast(@alignCast(user_data orelse return));
    var cmd_buf: [512]u8 = undefined;
    const cmd = mem.printSentinel(&cmd_buf, "xdg-open {s}", .{ctx.path}, 0) catch return;
    _ = gtk.g_spawn_command_line_async(cmd.ptr, null);
    if (ctx.mod.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}
