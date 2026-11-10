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

const ClipboardModule = @This();

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;
const sh = utils.sh;

const HistoryClickContext = struct {
    text: []const u8,
    mod: *ClipboardModule,
};

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
icon: []const u8,
max_length: usize,
interval_sec: u32,
clipboard: ?*gtk.GdkClipboard = null,
signal_id: c_ulong = 0,
timer_id: u32 = 0,
last_text: []const u8 = "",
history: ArrayList([]u8) = .empty,
history_contexts: ArrayList(*HistoryClickContext) = .empty,
popover: ?*gtk.GtkWidget = null,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*ClipboardModule {
    const this = try allocator.create(ClipboardModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "clipboard", settings);
    errdefer this.base.deinit();

    this.allocator = allocator;
    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getString("format") orelse "{icon} {text}";
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    this.icon = try allocator.dupe(u8, settings.getString("icon") orelse "📋");
    this.max_length = @intCast(settings.getInt("max-length") orelse 20);
    this.interval_sec = settings.getOr(u32, "interval", 2);
    if (this.interval_sec == 0) this.interval_sec = 2;

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    const display = gtk.gdk_display_get_default();
    const clip = if (display) |d| gtk.gdk_display_get_clipboard(d) else null;
    this.clipboard = clip;

    if (clip) |c| {
        this.signal_id = gtk.g_signal_connect_data(
            c,
            "changed",
            @ptrCast(&onClipboardChanged),
            this,
            null,
            0,
        );
        this.readClipboardAsync();
    } else {
        this.update();
        this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);
    }

    return this;
}

pub fn deinit(this: *ClipboardModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }

    for (this.history_contexts.items) |ctx| {
        this.allocator.destroy(ctx);
    }
    this.history_contexts.deinit(this.allocator);

    for (this.history.items) |item| {
        this.allocator.free(item);
    }
    this.history.deinit(this.allocator);

    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }

    this.allocator.free(this.icon);
    if (this.last_text.len > 0) this.allocator.free(this.last_text);
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();

    const alloc = this.base.allocator;
    this.base.deinit();
    alloc.destroy(this);
}

fn onClipboardChanged(clipboard: ?*gtk.GdkClipboard, user_data: ?*anyopaque) callconv(.c) void {
    _ = clipboard;
    const this: *ClipboardModule = @ptrCast(@alignCast(user_data orelse return));
    this.readClipboardAsync();
}

pub fn readClipboardAsync(this: *ClipboardModule) void {
    const clip = this.clipboard orelse return;
    gtk.gdk_clipboard_read_text_async(clip, null, @ptrCast(&onReadTextFinish), this);
}

fn onReadTextFinish(source: ?*anyopaque, res: ?*gtk.GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const this: *ClipboardModule = @ptrCast(@alignCast(user_data orelse return));
    const clip: ?*gtk.GdkClipboard = @ptrCast(source);
    if (clip == null or res == null) return;

    var err: ?*anyopaque = null;
    const text_ptr = gtk.gdk_clipboard_read_text_finish(clip, res, &err);
    if (err) |e| {
        gtk.g_error_free(e);
        return;
    }

    const raw = if (text_ptr) |tp| mem.span(tp) else "";
    this.applyText(raw);
    if (text_ptr) |tp| gtk.g_free(tp);
}

pub fn update(this: *ClipboardModule) void {
    if (this.clipboard != null) {
        this.readClipboardAsync();
        return;
    }

    const io = this.base.io;
    var paste_buf: [512]u8 = undefined;
    const raw = sh.runTrimBuf(io, "wl-paste -n --type text/plain 2>/dev/null", &paste_buf);
    this.applyText(raw);
}

fn applyText(this: *ClipboardModule, raw: []const u8) void {
    if (this.last_text.len > 0) this.allocator.free(this.last_text);
    this.last_text = this.allocator.dupe(u8, raw) catch "";

    // Track clipboard history (up to 15 items)
    if (raw.len > 0) {
        var already_top = false;
        if (this.history.items.len > 0 and mem.eql(u8, this.history.items[0], raw)) {
            already_top = true;
        }
        if (!already_top) {
            if (this.allocator.dupe(u8, raw)) |copy_item| {
                this.history.insert(this.allocator, 0, copy_item) catch {
                    this.allocator.free(copy_item);
                };
                if (this.history.items.len > 15) {
                    const popped = this.history.pop();
                    if (popped) |p| this.allocator.free(p);
                }
            } else |_| {}
        }
    }

    var display_buf: [256]u8 = undefined;
    var display_text: []const u8 = "";

    if (this.last_text.len == 0) {
        display_text = "[Empty]";
    } else {
        // Sanitize newlines into spaces for single-line display
        const copy_len = @min(this.last_text.len, display_buf.len - 4);
        @memcpy(display_buf[0..copy_len], this.last_text[0..copy_len]);
        for (display_buf[0..copy_len]) |*c| {
            if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
        }

        if (copy_len > this.max_length) {
            display_buf[this.max_length] = '.';
            display_buf[this.max_length + 1] = '.';
            display_buf[this.max_length + 2] = '.';
            display_text = display_buf[0 .. this.max_length + 3];
        } else {
            display_text = display_buf[0..copy_len];
        }
    }

    this.replacer.clear();
    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKey("text", display_text) catch {};
    this.replacer.addKey("full_text", if (this.last_text.len > 0) this.last_text else "Clipboard empty") catch {};

    var render_buf: [256]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [512]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        this.base.setTooltip(if (this.last_text.len > 0) this.last_text else "Clipboard empty");
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *ClipboardModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    const this: *ClipboardModule = @ptrCast(@alignCast(user_data orelse return false));
    if (btn_num == 1 or btn_num == 3) {
        this.toggleClipboardPopover();
        return true;
    }
    return false;
}

pub fn toggleClipboardPopover(this: *ClipboardModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    for (this.history_contexts.items) |ctx| {
        this.allocator.destroy(ctx);
    }
    this.history_contexts.clearRetainingCapacity();

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 6);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "clipboard-popover");

        const header_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
        if (header_box) |hb| {
            const title = gtk.gtk_label_new("Clipboard History");
            if (title) |t| {
                gtk.gtk_widget_add_css_class(t, "title");
                gtk.gtk_box_append(@ptrCast(hb), t);
            }

            const clear_btn = gtk.gtk_button_new_with_label("Clear");
            if (clear_btn) |cb| {
                _ = gtk.g_signal_connect_data(cb, "clicked", @ptrCast(&onClearHistoryClicked), this, null, 0);
                gtk.gtk_box_append(@ptrCast(hb), cb);
            }
            gtk.gtk_box_append(@ptrCast(b), hb);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        if (this.history.items.len == 0) {
            const empty_lbl = gtk.gtk_label_new("History is empty");
            if (empty_lbl) |el| gtk.gtk_box_append(@ptrCast(b), el);
        } else {
            for (this.history.items) |item_str| {
                var preview_buf: [80]u8 = undefined;
                const copy_len = @min(item_str.len, preview_buf.len - 4);
                @memcpy(preview_buf[0..copy_len], item_str[0..copy_len]);
                for (preview_buf[0..copy_len]) |*ch| {
                    if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') ch.* = ' ';
                }
                const label_text = if (item_str.len > copy_len)
                    mem.printSentinel(&preview_buf, "{s}...", .{preview_buf[0..copy_len]}, 0) catch "..."
                else
                    mem.printSentinel(&preview_buf, "{s}", .{preview_buf[0..copy_len]}, 0) catch "...";

                const btn = gtk.gtk_button_new_with_label(label_text.ptr);
                if (btn) |btn_w| {
                    const ctx = this.allocator.create(HistoryClickContext) catch continue;
                    ctx.* = .{ .text = item_str, .mod = this };
                    this.history_contexts.append(this.allocator, ctx) catch {
                        this.allocator.destroy(ctx);
                        continue;
                    };
                    _ = gtk.g_signal_connect_data(btn_w, "clicked", @ptrCast(&onHistoryItemClicked), ctx, null, 0);
                    gtk.gtk_box_append(@ptrCast(b), btn_w);
                }
            }
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onClearHistoryClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *ClipboardModule = @ptrCast(@alignCast(user_data orelse return));
    for (this.history.items) |item| {
        this.allocator.free(item);
    }
    this.history.clearRetainingCapacity();
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}

fn onHistoryItemClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const ctx: *HistoryClickContext = @ptrCast(@alignCast(user_data orelse return));
    if (ctx.mod.clipboard) |clip| {
        var z_buf: [512]u8 = undefined;
        if (mem.printSentinel(&z_buf, "{s}", .{ctx.text}, 0)) |z_str| {
            gtk.gdk_clipboard_set_text(clip, z_str.ptr);
        } else |_| {}
    }
    if (ctx.mod.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}
