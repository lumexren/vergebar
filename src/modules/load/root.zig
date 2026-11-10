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

const LoadModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const fmt = std.fmt;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;
const sysinfo = @import("sysinfo");

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
interval_sec: u32,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*LoadModule {
    const this = try allocator.create(LoadModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "load", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getOr([]const u8, "format", "{load1}");
    const interval = settings.getOr(u32, "interval", 10);

    var tmpl: Template = try .compile(allocator, format_str);
    errdefer tmpl.deinit();

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .template = tmpl,
        .template_tooltip = if (base_mod.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null,
        .interval_sec = interval,
    };

    this.update();
    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *LoadModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *LoadModule) void {
    const lavg = sysinfo.load.read(this.base.io) orelse return;

    var l1_buf: [16]u8 = undefined;
    var l5_buf: [16]u8 = undefined;
    var l15_buf: [16]u8 = undefined;
    const l1 = mem.print(&l1_buf, "{d:.2}", .{lavg.load1}) catch "0.00";
    const l5 = mem.print(&l5_buf, "{d:.2}", .{lavg.load5}) catch "0.00";
    const l15 = mem.print(&l15_buf, "{d:.2}", .{lavg.load15}) catch "0.00";

    const replacer = &this.replacer;
    replacer.clear();

    replacer.addKey("load1", l1) catch {};
    replacer.addKey("load5", l5) catch {};
    replacer.addKey("load15", l15) catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = this.template.renderBuf(replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [256]u8 = undefined;
        if (tt_tmpl.renderBuf(replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "Load average: {s}, {s}, {s}", .{ l1, l5, l15 }) catch "Load";
        this.base.setTooltip(tt);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *LoadModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
