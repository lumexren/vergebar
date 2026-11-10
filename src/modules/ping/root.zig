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

const PingModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;
const atomic = std.atomic;
const gtk = @import("gtk");
const sysinfo = @import("sysinfo");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const utils = @import("utils");
const Replacer = utils.Replacer;
const Template = Replacer.Template;

base: *BaseModule,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
target_domain: []const u8,
icon: []const u8,
warning_threshold: f64,
critical_threshold: f64,
interval_sec: u32,
timer_id: u32 = 0,
worker_thread: ?Thread = null,
running: atomic.Value(bool) = .init(true),
pinging: atomic.Value(bool) = .init(false),
latest_latency: atomic.Value(i64) = .init(-1),
min_latency: atomic.Value(i64) = .init(-1),
max_latency: atomic.Value(i64) = .init(0),
avg_latency: atomic.Value(i64) = .init(0),
total_latency: i64 = 0,
ping_count: i64 = 0,
resolved_ip: [64]u8 = @splat(0),
resolved_ip_len: usize = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*PingModule {
    const this = try allocator.create(PingModule);
    errdefer allocator.destroy(this);

    this.base = try .initFromSettings(io, allocator, name, "ping", settings);
    errdefer this.base.deinit();

    this.replacer = .init(allocator);
    errdefer this.replacer.deinit();

    const fmt_str = settings.getOr([]const u8, "format", "{icon}  {latency}ms");
    this.template = try .compile(allocator, fmt_str);
    errdefer this.template.deinit();

    this.template_tooltip = if (this.base.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null;

    const domain = settings.getString("target") orelse (settings.getString("target-domain") orelse "1.1.1.1");
    this.target_domain = try allocator.dupe(u8, domain);
    this.icon = try allocator.dupe(u8, settings.getOr([]const u8, "icon", "󰛳"));
    this.warning_threshold = settings.getFloat("warning-threshold") orelse (settings.getFloat("warning_threshold") orelse 100.0);
    this.critical_threshold = settings.getFloat("critical-threshold") orelse (settings.getFloat("critical_threshold") orelse 250.0);
    this.interval_sec = settings.getOr(u32, "interval", 2);

    this.update();

    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    this.triggerPing();

    return this;
}

pub fn deinit(this: *PingModule) void {
    const alloc = this.base.allocator;
    this.running.store(false, .seq_cst);
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
    }
    if (this.worker_thread) |thread| {
        thread.join();
        this.worker_thread = null;
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    alloc.free(this.target_domain);
    alloc.free(this.icon);
    this.base.deinit();
    alloc.destroy(this);
}

fn triggerPing(this: *PingModule) void {
    if (this.pinging.swap(true, .seq_cst)) return;
    if (this.worker_thread) |thread| {
        thread.join();
        this.worker_thread = null;
    }
    this.worker_thread = Thread.spawn(.{}, pingThreadFn, .{this}) catch null;
    if (this.worker_thread == null) {
        this.pinging.store(false, .seq_cst);
    }
}

fn pingThreadFn(this: *PingModule) void {
    defer this.pinging.store(false, .seq_cst);

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const resolved_opt = sysinfo.network.lib.resolveIP(io, this.base.allocator, this.target_domain) catch null;
    defer if (resolved_opt) |r| this.base.allocator.free(r);

    const ip_str = resolved_opt orelse this.target_domain;
    const copy_len = @min(ip_str.len, this.resolved_ip.len);
    @memcpy(this.resolved_ip[0..copy_len], ip_str[0..copy_len]);
    this.resolved_ip_len = copy_len;

    const target_addr = Io.net.IpAddress.parseIp4(ip_str, 0) catch return;

    const local_addr = Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch return;
    const socket = local_addr.bind(io, .{ .mode = .dgram, .protocol = .icmp }) catch return;
    defer socket.close(io);

    var ping_buffer: [64]u8 = @splat(0);
    sysinfo.network.lib.createIcmpPacket(&ping_buffer);

    const PING_IDENTIFIER: u16 = 0xCAFE;
    const sequence: u16 = 1;

    // Stamp header
    mem.writeInt(u16, ping_buffer[2..4][0..2], 0, .big);
    mem.writeInt(u16, ping_buffer[4..6][0..2], PING_IDENTIFIER, .big);
    mem.writeInt(u16, ping_buffer[6..8][0..2], sequence, .big);

    // Checksum
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < ping_buffer.len) : (i += 2) sum += (@as(u32, ping_buffer[i]) << 8) | ping_buffer[i + 1];
    if (i < ping_buffer.len) sum += @as(u32, ping_buffer[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    const checksum: u16 = @truncate(~sum);
    mem.writeInt(u16, ping_buffer[2..4][0..2], checksum, .big);

    const raw_start = Io.Clock.now(.boot, io);
    var target_copy = target_addr;
    _ = socket.send(io, &target_copy, &ping_buffer) catch return;

    var recv_buf: [64]u8 = undefined;
    const to: Io.Timeout = .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(2) } };
    const n = socket.receiveTimeout(io, &recv_buf, to) catch return;
    if (n.data.len < 8) return;

    const raw_end = Io.Clock.now(.boot, io);
    const latency_ms = @as(i64, @intCast(@max(0, raw_end.toMilliseconds() - raw_start.toMilliseconds())));

    this.latest_latency.store(latency_ms, .seq_cst);

    this.ping_count += 1;
    this.total_latency += latency_ms;
    const cur_min = this.min_latency.load(.seq_cst);
    if (cur_min < 0 or latency_ms < cur_min) this.min_latency.store(latency_ms, .seq_cst);
    const cur_max = this.max_latency.load(.seq_cst);
    if (latency_ms > cur_max) this.max_latency.store(latency_ms, .seq_cst);
    this.avg_latency.store(@divTrunc(this.total_latency, this.ping_count), .seq_cst);

    _ = gtk.g_idle_add(@ptrCast(&onIdleUpdate), this);
}

fn onIdleUpdate(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *PingModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 0; // run once
}

pub fn update(this: *PingModule) void {
    const lat = this.latest_latency.load(.seq_cst);
    const lat_f64: f64 = @floatFromInt(@max(0, lat));

    this.replacer.clear();
    this.replacer.addKey("icon", this.icon) catch {};
    this.replacer.addKey("target", this.target_domain) catch {};

    const ip_str = if (this.resolved_ip_len > 0) this.resolved_ip[0..this.resolved_ip_len] else this.target_domain;
    this.replacer.addKey("ip", ip_str) catch {};

    if (lat >= 0) {
        this.replacer.addKeyAny("latency", lat) catch {};
    } else {
        this.replacer.addKey("latency", "--") catch {};
    }
    this.replacer.addKeyAny("min_latency", @max(0, this.min_latency.load(.seq_cst))) catch {};
    this.replacer.addKeyAny("avg_latency", this.avg_latency.load(.seq_cst)) catch {};
    this.replacer.addKeyAny("max_latency", this.max_latency.load(.seq_cst)) catch {};

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
        const tt = mem.print(&tt_buf, "Target: {s} ({s})\nLatency: {d} ms\nMin: {d} | Avg: {d} | Max: {d}", .{
            this.target_domain,
            ip_str,
            lat,
            @max(0, this.min_latency.load(.seq_cst)),
            this.avg_latency.load(.seq_cst),
            this.max_latency.load(.seq_cst),
        }) catch "Ping";
        this.base.setTooltip(tt);
    }

    const is_warning = lat >= 0 and lat_f64 >= this.warning_threshold and lat_f64 < this.critical_threshold;
    const is_critical = lat >= 0 and lat_f64 >= this.critical_threshold;
    this.base.setClasses(is_warning, is_critical);
    _ = this.base.applyState(lat_f64, false);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *PingModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.triggerPing();
    return 1;
}
