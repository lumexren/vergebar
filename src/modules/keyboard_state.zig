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
const json = std.json;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const Context = @import("utils").Context;

pub const KeyboardStateModule = struct {
    base: *BaseModule,
    allocator: Allocator,
    format: []const u8,
    format_icons: ?json.Value,
    timer_id: u32 = 0,

    pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings) !*KeyboardStateModule {
        const self = try allocator.create(KeyboardStateModule);
        errdefer allocator.destroy(self);

        const base_mod = try BaseModule.initFromSettings(allocator, name, "keyboard-state", settings);
        errdefer base_mod.deinit();

        const format_str = settings.getString("format") orelse "{name} {icon}";

        self.* = .{
            .base = base_mod,
            .allocator = allocator,
            .format = try allocator.dupe(u8, format_str),
            .format_icons = if (settings.value == .object) settings.value.object.get("format-icons") else null,
        };

        self.update();
        self.timer_id = gtk.g_timeout_add(500, @ptrCast(&onTimeout), self);

        return self;
    }

    pub fn deinit(self: *KeyboardStateModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.allocator.free(self.format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *KeyboardStateModule) void {
        const caps = isLedActive("capslock");
        const num = isLedActive("numlock");

        var replacer: Replacer = .init(self.allocator);
        defer replacer.deinit();

        replacer.addKey("capslock", if (caps) "CAPS" else "") catch {};
        replacer.addKey("numlock", if (num) "NUM" else "") catch {};
        replacer.addKey("name", if (caps) "CAPS" else if (num) "NUM" else "") catch {};
        replacer.addKey("icon", if (caps) "󰬈" else if (num) "󰎦" else "") catch {};

        const rendered = replacer.render(self.format) catch self.format;
        defer if (rendered.ptr != self.format.ptr) self.allocator.free(rendered);

        self.base.setText(rendered);

        if (caps) self.base.addCssClass("capslock") else self.base.removeCssClass("capslock");
        if (num) self.base.addCssClass("numlock") else self.base.removeCssClass("numlock");

        var tt_buf: [128]u8 = undefined;
        const tt = mem.print(&tt_buf, "Caps: {s} | Num: {s}", .{ if (caps) "ON" else "OFF", if (num) "ON" else "OFF" }) catch "Keyboard";
        self.base.setTooltip(tt);
    }
};

fn isLedActive(led_name: []const u8) bool {
    const ctx = Context.get() orelse return false;
    var dir = Io.Dir.openDirAbsolute(ctx.io, "/sys/class/leds", .{ .iterate = true }) catch return false;
    defer dir.close(ctx.io);

    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (mem.find(u8, entry.name, led_name) != null) {
            var path_buf: [256]u8 = undefined;
            const b_path = mem.print(&path_buf, "/sys/class/leds/{s}/brightness", .{entry.name}) catch continue;
            path_buf[b_path.len] = 0;

            var buf: [16]u8 = undefined;
            if (Context.readSysfsLine(path_buf[0..b_path.len :0], &buf)) |trimmed| {
                if (mem.eql(u8, trimmed, "1") or (!mem.eql(u8, trimmed, "0") and trimmed.len > 0)) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *KeyboardStateModule = @ptrCast(@alignCast(user_data orelse return 0));
    self.update();
    return 1;
}
