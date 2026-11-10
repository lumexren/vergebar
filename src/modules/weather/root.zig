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

const WeatherModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;
const atomic = std.atomic;
const json = std.json;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;
const sh = utils.sh;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
city: ?[]const u8 = null,
interval_sec: u32,
timer_id: u32 = 0,
worker_thread: ?Thread = null,
running: atomic.Value(bool) = .init(true),
fetching: atomic.Value(bool) = .init(false),
// Weather cached state
weather_temp: []const u8 = "",
weather_feels: []const u8 = "",
weather_humidity: []const u8 = "",
weather_wind: []const u8 = "",
weather_desc: []const u8 = "",
weather_icon: []const u8 = "",
weather_city: []const u8 = "",
popover: ?*gtk.GtkWidget = null,

const WeatherPayload = struct {
    module: *WeatherModule,
    temp: []const u8,
    feels: []const u8,
    humidity: []const u8,
    wind: []const u8,
    desc: []const u8,
    icon: []const u8,
    city: []const u8,

    fn onCallback(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
        const payload: *WeatherPayload = @ptrCast(@alignCast(user_data orelse return 0));
        defer {
            const alloc = payload.module.allocator;
            alloc.free(payload.temp);
            alloc.free(payload.feels);
            alloc.free(payload.humidity);
            alloc.free(payload.wind);
            alloc.free(payload.desc);
            alloc.free(payload.icon);
            alloc.free(payload.city);
            alloc.destroy(payload);
        }

        if (payload.module.running.load(.seq_cst)) {
            payload.module.applyPayload(payload);
        }
        return 0;
    }
};

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*WeatherModule {
    const this = try allocator.create(WeatherModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "weather", settings);
    errdefer this.base.deinit();

    this.allocator = allocator;
    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getString("format") orelse "{icon} {temp}°C";
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    if (settings.getString("city")) |c| {
        this.city = try allocator.dupe(u8, c);
    } else {
        this.city = null;
    }

    this.interval_sec = settings.getOr(u32, "interval", 1800);
    if (this.interval_sec < 60) this.interval_sec = 60;

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    this.base.setText("Weather...");
    this.base.setTooltip("Fetching current weather...");

    this.base.custom_click_handler = &onClick;
    this.base.custom_click_data = this;

    this.triggerFetch();

    return this;
}

pub fn deinit(this: *WeatherModule) void {
    if (this.popover) |pop| {
        gtk.gtk_widget_unparent(pop);
        this.popover = null;
    }
    this.running.store(false, .seq_cst);

    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }

    if (this.worker_thread) |th| {
        th.join();
        this.worker_thread = null;
    }

    if (this.city) |c| this.allocator.free(c);
    this.clearCachedState();
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();

    const alloc = this.base.allocator;
    this.base.deinit();
    alloc.destroy(this);
}

fn clearCachedState(this: *WeatherModule) void {
    if (this.weather_temp.len > 0) this.allocator.free(this.weather_temp);
    if (this.weather_feels.len > 0) this.allocator.free(this.weather_feels);
    if (this.weather_humidity.len > 0) this.allocator.free(this.weather_humidity);
    if (this.weather_wind.len > 0) this.allocator.free(this.weather_wind);
    if (this.weather_desc.len > 0) this.allocator.free(this.weather_desc);
    if (this.weather_icon.len > 0) this.allocator.free(this.weather_icon);
    if (this.weather_city.len > 0) this.allocator.free(this.weather_city);
    this.weather_temp = "";
    this.weather_feels = "";
    this.weather_humidity = "";
    this.weather_wind = "";
    this.weather_desc = "";
    this.weather_icon = "";
    this.weather_city = "";
}

pub fn applyPayload(this: *WeatherModule, payload: *const WeatherPayload) void {
    this.clearCachedState();
    this.weather_temp = this.allocator.dupe(u8, payload.temp) catch "";
    this.weather_feels = this.allocator.dupe(u8, payload.feels) catch "";
    this.weather_humidity = this.allocator.dupe(u8, payload.humidity) catch "";
    this.weather_wind = this.allocator.dupe(u8, payload.wind) catch "";
    this.weather_desc = this.allocator.dupe(u8, payload.desc) catch "";
    this.weather_icon = this.allocator.dupe(u8, payload.icon) catch "";
    this.weather_city = this.allocator.dupe(u8, payload.city) catch "";
    this.update();
}

fn mapWeatherCodeToIcon(desc: []const u8) []const u8 {
    if (mem.find(u8, desc, "Sunny") != null or mem.find(u8, desc, "Clear") != null) return "☀️";
    if (mem.find(u8, desc, "Partly") != null) return "⛅";
    if (mem.find(u8, desc, "Cloudy") != null or mem.find(u8, desc, "Overcast") != null) return "☁️";
    if (mem.find(u8, desc, "Mist") != null or mem.find(u8, desc, "Fog") != null) return "🌫️";
    if (mem.find(u8, desc, "Thunder") != null or mem.find(u8, desc, "Storm") != null) return "🌩️";
    if (mem.find(u8, desc, "Snow") != null or mem.find(u8, desc, "Blizzard") != null) return "❄️";
    if (mem.find(u8, desc, "Rain") != null or mem.find(u8, desc, "Drizzle") != null) return "🌧️";
    return "🌤️";
}

fn weatherWorkerFn(this: *WeatherModule) void {
    defer this.fetching.store(false, .seq_cst);

    var url_buf: [256]u8 = undefined;
    const url = if (this.city) |c|
        mem.print(&url_buf, "https://wttr.in/{s}?format=j1", .{c}) catch return
    else
        mem.print(&url_buf, "https://wttr.in/?format=j1", .{}) catch return;

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const alloc = this.allocator;

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();

    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &allocating.writer,
    }) catch return;

    if (res.status != .ok) return;

    const output = allocating.written();
    if (output.len == 0 or !this.running.load(.seq_cst)) return;

    const parsed = json.parseFromSlice(json.Value, alloc, output, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    const cc_val = parsed.value.object.get("current_condition") orelse return;
    if (cc_val != .array or cc_val.array.items.len == 0) return;

    const cur = cc_val.array.items[0];
    if (cur != .object) return;

    const temp_c = cur.object.get("temp_C");
    const feels_c = cur.object.get("FeelsLikeC");
    const humidity = cur.object.get("humidity");
    const wind = cur.object.get("windspeedKmph");

    var desc_str: []const u8 = "Clear";
    if (cur.object.get("weatherDesc")) |wd| {
        if (wd == .array and wd.array.items.len > 0 and wd.array.items[0] == .object) {
            if (wd.array.items[0].object.get("value")) |v| {
                if (v == .string) desc_str = v.string;
            }
        }
    }

    var city_str: []const u8 = this.city orelse "Current Location";
    if (parsed.value.object.get("nearest_area")) |na| {
        if (na == .array and na.array.items.len > 0 and na.array.items[0] == .object) {
            if (na.array.items[0].object.get("areaName")) |an| {
                if (an == .array and an.array.items.len > 0 and an.array.items[0] == .object) {
                    if (an.array.items[0].object.get("value")) |v| {
                        if (v == .string) city_str = v.string;
                    }
                }
            }
        }
    }

    const icon_str = mapWeatherCodeToIcon(desc_str);

    const payload = this.allocator.create(WeatherPayload) catch return;
    errdefer this.allocator.destroy(payload);

    const t_s = if (temp_c) |t| (if (t == .string) t.string else "") else "";
    const f_s = if (feels_c) |f| (if (f == .string) f.string else "") else "";
    const h_s = if (humidity) |h| (if (h == .string) h.string else "") else "";
    const w_s = if (wind) |w| (if (w == .string) w.string else "") else "";

    payload.* = .{
        .module = this,
        .temp = this.allocator.dupe(u8, t_s) catch return,
        .feels = this.allocator.dupe(u8, f_s) catch return,
        .humidity = this.allocator.dupe(u8, h_s) catch return,
        .wind = this.allocator.dupe(u8, w_s) catch return,
        .desc = this.allocator.dupe(u8, desc_str) catch return,
        .icon = this.allocator.dupe(u8, icon_str) catch return,
        .city = this.allocator.dupe(u8, city_str) catch return,
    };

    _ = gtk.g_idle_add(@ptrCast(&WeatherPayload.onCallback), payload);
}

pub fn triggerFetch(this: *WeatherModule) void {
    if (!this.running.load(.seq_cst)) return;
    if (this.fetching.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return;

    if (this.worker_thread) |th| th.join();
    this.worker_thread = Thread.spawn(.{}, weatherWorkerFn, .{this}) catch {
        this.fetching.store(false, .seq_cst);
        return;
    };
}

pub fn update(this: *WeatherModule) void {
    if (this.weather_temp.len == 0) {
        return;
    }

    this.replacer.clear();
    this.replacer.addKey("icon", if (this.weather_icon.len > 0) this.weather_icon else "🌤️") catch {};
    this.replacer.addKey("temp", this.weather_temp) catch {};
    this.replacer.addKey("feels_like", if (this.weather_feels.len > 0) this.weather_feels else this.weather_temp) catch {};
    this.replacer.addKey("humidity", this.weather_humidity) catch {};
    this.replacer.addKey("wind", this.weather_wind) catch {};
    this.replacer.addKey("desc", this.weather_desc) catch {};
    this.replacer.addKey("city", this.weather_city) catch {};

    var render_buf: [256]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch "";
    this.base.setText(rendered);

    if (this.template_tooltip) |*tt_tmpl| {
        var tt_buf: [512]u8 = undefined;
        if (tt_tmpl.renderBuf(&this.replacer, &tt_buf)) |tt| {
            this.base.setTooltip(tt);
        } else |_| {}
    } else {
        var tt_buf: [256]u8 = undefined;
        const tt = mem.print(&tt_buf, "{s}\n{s}\nTemp: {s}°C (Feels like: {s}°C)\nHumidity: {s}%\nWind: {s} km/h", .{
            this.weather_city,
            this.weather_desc,
            this.weather_temp,
            this.weather_feels,
            this.weather_humidity,
            this.weather_wind,
        }) catch "Weather";
        this.base.setTooltip(tt);
    }
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *WeatherModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.triggerFetch();
    return 1;
}

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    _ = btn_num;
    const this: *WeatherModule = @ptrCast(@alignCast(user_data orelse return false));
    this.toggleWeatherPopover();
    return true;
}

pub fn toggleWeatherPopover(this: *WeatherModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 6);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "weather-popover");

        const city_name = if (this.weather_city.len > 0) this.weather_city else (if (this.city) |c| c else "Weather");
        var title_buf: [64]u8 = undefined;
        const title_str = mem.printSentinel(&title_buf, "{s}", .{city_name}, 0) catch "Weather";
        const header = gtk.gtk_label_new(title_str.ptr);
        if (header) |h| {
            gtk.gtk_widget_add_css_class(h, "title");
            gtk.gtk_box_append(@ptrCast(b), h);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        var temp_buf: [64]u8 = undefined;
        const temp_str = mem.printSentinel(&temp_buf, "{s} {s}°C ({s})", .{ this.weather_icon, this.weather_temp, this.weather_desc }, 0) catch "";
        if (temp_str.len > 0) {
            const temp_lbl = gtk.gtk_label_new(temp_str.ptr);
            if (temp_lbl) |tl| gtk.gtk_box_append(@ptrCast(b), tl);
        }

        var details_buf: [128]u8 = undefined;
        const det_str = mem.printSentinel(&details_buf, "Feels like: {s}°C ・ Humidity: {s}% ・ Wind: {s} km/h", .{ this.weather_feels, this.weather_humidity, this.weather_wind }, 0) catch "";
        if (det_str.len > 0) {
            const det_lbl = gtk.gtk_label_new(det_str.ptr);
            if (det_lbl) |dl| gtk.gtk_box_append(@ptrCast(b), dl);
        }

        const refresh_btn = gtk.gtk_button_new_with_label("Refresh");
        if (refresh_btn) |rb| {
            _ = gtk.g_signal_connect_data(rb, "clicked", @ptrCast(&onRefreshClicked), this, null, 0);
            gtk.gtk_box_append(@ptrCast(b), rb);
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onRefreshClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *WeatherModule = @ptrCast(@alignCast(user_data orelse return));
    this.triggerFetch();
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}
