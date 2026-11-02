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

pub const lib = @import("lib.zig");
pub const NetworkError = @import("NetworkError.zig").NetworkError;
pub const RouteInfo = @import("RouteInfo.zig");
pub const NetworkStats = @import("NetworkStats.zig");
pub const Header = @import("Header.zig");

pub const WifiInfo = struct {
    ssid: ?[]const u8 = null,
    signal_strength: u8 = 0,
    signal_dbm: ?i32 = null,
    is_wireless: bool = false,

    pub fn deinit(self: *WifiInfo, allocator: Allocator) void {
        if (self.ssid) |s| allocator.free(s);
        self.* = undefined;
    }
};

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const linux = std.os.linux;

const SIOCGIFADDR: u32 = 0x8915;
const SIOCGIWESSID: u32 = 0x8B1B;
const ROUTE_PATH = "/proc/net/route";
const DEV_PATH = "/proc/net/dev";
const WIRELESS_PATH = "/proc/net/wireless";

const iw_point = extern struct {
    pointer: ?*anyopaque,
    length: u16,
    flags: u16,
};

const iwreq = extern struct {
    name: [16]u8 = @splat(0),
    point: iw_point,
    pad: [4]u8 = @splat(0),
};

/// Formats an IPv4 address from 4 bytes.
fn formatIPv4(allocator: Allocator, bytes: [4]u8) ![]const u8 {
    return allocator.print("{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
}

/// Reads file content into buffer.
fn readFile(io: Io, path: []const u8, buffer: []u8) ![]const u8 {
    var file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const n = try reader.interface.readSliceShort(buffer);
    return buffer[0..n];
}

/// Get default network interface and gateway from /proc/net/route.
pub fn getDefaultRoute(io: Io, allocator: Allocator) !RouteInfo {
    var buffer: [4096]u8 = undefined;
    const content = try readFile(io, ROUTE_PATH, &buffer);

    var lines = mem.splitScalar(u8, content, '\n');
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var fields = mem.tokenizeAny(u8, line, " \t");
        const iface = fields.next() orelse continue;
        const dest = fields.next() orelse continue;
        const gateway = fields.next() orelse continue;

        if (!mem.eql(u8, dest, "00000000")) continue;

        const gw_hex = try fmt.parseInt(u32, gateway, 16);
        const gw_bytes: [4]u8 = @bitCast(mem.nativeToLittle(u32, gw_hex));

        return .{
            .interface = try allocator.dupe(u8, iface),
            .gateway = try formatIPv4(allocator, gw_bytes),
        };
    }

    return NetworkError.NoDefaultRoute;
}

/// Get local IP address for an interface using ioctl.
pub fn getLocalIP(allocator: Allocator, interface: []const u8) ![]const u8 {
    const sock_result = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (sock_result < 0) return allocator.dupe(u8, "N/A");

    const sock: linux.fd_t = @intCast(sock_result);
    defer _ = linux.close(sock);

    var ifr: linux.ifreq = mem.zeroes(linux.ifreq);
    const len = @min(interface.len, 15);
    @memcpy(ifr.ifrn.name[0..len], interface[0..len]);

    if (linux.ioctl(sock, SIOCGIFADDR, @intFromPtr(&ifr)) != 0) return allocator.dupe(u8, "N/A");

    const addr: *const linux.sockaddr.in = @ptrCast(@alignCast(&ifr.ifru.addr));
    return formatIPv4(allocator, @bitCast(addr.addr));
}

/// Get WiFi information (SSID, signal strength, signal level) for a given interface.
pub fn getWifiInfo(io: Io, allocator: Allocator, interface: []const u8) WifiInfo {
    var info = WifiInfo{};

    var buffer: [2048]u8 = undefined;
    if (readFile(io, WIRELESS_PATH, &buffer)) |content| {
        parseWirelessStats(content, interface, &info);
    } else |_| {}

    const sock_result = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (sock_result >= 0) {
        const sock: linux.fd_t = @intCast(sock_result);
        defer _ = linux.close(sock);

        var essid_buf: [33]u8 = @splat(0);
        var req: iwreq = .{
            .point = .{
                .pointer = &essid_buf,
                .length = 32,
                .flags = 0,
            },
        };
        const len = @min(interface.len, 15);
        @memcpy(req.name[0..len], interface[0..len]);

        if (linux.ioctl(sock, SIOCGIWESSID, @intFromPtr(&req)) == 0) {
            info.is_wireless = true;
            const ssid_len = @min(req.point.length, 32);
            const trimmed = mem.trim(u8, essid_buf[0..ssid_len], "\x00 \t\n\r");
            if (trimmed.len > 0) {
                info.ssid = allocator.dupe(u8, trimmed) catch null;
            }
        }
    }

    return info;
}

pub fn parseWirelessStats(content: []const u8, interface: []const u8, info: *WifiInfo) void {
    var lines = mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = mem.findScalar(u8, line, ':') orelse continue;
        const iface = mem.trim(u8, line[0..colon], " \t");
        if (!mem.eql(u8, iface, interface)) continue;

        info.is_wireless = true;

        var fields = mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        _ = fields.next();
        if (fields.next()) |link_str| {
            const link_clean = mem.trimEnd(u8, link_str, ".");
            if (fmt.parseInt(u32, link_clean, 10)) |link| {
                info.signal_strength = if (link <= 70) @intCast(@min(100, (link * 100) / 70)) else if (link <= 100) @intCast(link) else 100;
            } else |_| {}
        }
        if (fields.next()) |level_str| {
            const link_clean = mem.trimEnd(u8, level_str, ".");
            if (fmt.parseInt(i32, link_clean, 10)) |level| {
                info.signal_dbm = level;
            } else |_| {}
        }
        break;
    }
}

/// Read network statistics from /proc/net/dev.
pub fn getNetworkStats(io: Io, interface: []const u8, timestamp: i64) !NetworkStats {
    var buffer: [8192]u8 = undefined;
    const content = try readFile(io, DEV_PATH, &buffer);

    var lines = mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon = mem.findScalar(u8, line, ':') orelse continue;
        const iface = mem.trim(u8, line[0..colon], " \t");

        if (!mem.eql(u8, iface, interface)) continue;

        var fields = mem.tokenizeAny(u8, line[colon + 1 ..], " \t");

        const rx_bytes = try fmt.parseInt(u64, fields.next() orelse return NetworkError.InvalidDevFormat, 10);

        inline for (0..7) |_| _ = fields.next() orelse return NetworkError.InvalidDevFormat;

        const tx_bytes = try fmt.parseInt(u64, fields.next() orelse return NetworkError.InvalidDevFormat, 10);

        return .{ .rx_bytes = rx_bytes, .tx_bytes = tx_bytes, .timestamp = timestamp };
    }

    return NetworkError.InterfaceNotFound;
}

const testing = std.testing;

test "NetworkStats.calculateRates - normal" {
    const old = NetworkStats{ .rx_bytes = 1000, .tx_bytes = 500, .timestamp = 0 };
    const new = NetworkStats{ .rx_bytes = 2000, .tx_bytes = 1500, .timestamp = 1 };
    const rates = NetworkStats.calculateRates(old, new);

    try testing.expectApproxEqAbs(@as(f64, 1000.0), rates.download, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1000.0), rates.upload, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2000.0), rates.total, 0.001);
}

test "NetworkStats.calculateRates - zero/negative time" {
    const same_time = NetworkStats.calculateRates(
        .{ .rx_bytes = 1000, .tx_bytes = 500, .timestamp = 5 },
        .{ .rx_bytes = 2000, .tx_bytes = 1500, .timestamp = 5 },
    );
    try testing.expectApproxEqAbs(@as(f64, 0.0), same_time.total, 0.001);

    const negative = NetworkStats.calculateRates(
        .{ .rx_bytes = 1000, .tx_bytes = 500, .timestamp = 10 },
        .{ .rx_bytes = 2000, .tx_bytes = 1500, .timestamp = 5 },
    );
    try testing.expectApproxEqAbs(@as(f64, 0.0), negative.total, 0.001);
}

test "NetworkStats.calculateRates - counter wraparound" {
    const rates = NetworkStats.calculateRates(
        .{ .rx_bytes = 5000, .tx_bytes = 3000, .timestamp = 0 },
        .{ .rx_bytes = 1000, .tx_bytes = 500, .timestamp = 1 },
    );
    try testing.expectApproxEqAbs(@as(f64, 0.0), rates.total, 0.001);
}

test "getDefaultRoute" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const route = getDefaultRoute(io, testing.allocator) catch |err| {
        if (err == error.FileNotFound or err == NetworkError.NoDefaultRoute) return;
        return err;
    };
    defer testing.allocator.free(route.interface);
    defer testing.allocator.free(route.gateway);

    try testing.expect(route.interface.len > 0);
    try testing.expect(route.gateway.len > 0);
}

test "getLocalIP - valid interface" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const route = getDefaultRoute(io, testing.allocator) catch |err| {
        if (err == error.FileNotFound or err == NetworkError.NoDefaultRoute) return;
        return err;
    };
    defer testing.allocator.free(route.interface);
    defer testing.allocator.free(route.gateway);

    const ip = try getLocalIP(testing.allocator, route.interface);
    defer testing.allocator.free(ip);

    try testing.expect(ip.len > 0);
}

test "getLocalIP - invalid interface" {
    const ip = try getLocalIP(testing.allocator, "nonexistent_iface");
    defer testing.allocator.free(ip);
    try testing.expectEqualStrings("N/A", ip);
}

test "getNetworkStats - valid interface" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const route = getDefaultRoute(io, testing.allocator) catch |err| {
        if (err == error.FileNotFound or err == NetworkError.NoDefaultRoute) return;
        return err;
    };
    defer testing.allocator.free(route.interface);
    defer testing.allocator.free(route.gateway);

    const stats = getNetworkStats(io, route.interface, 42) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    try testing.expect(stats.timestamp == 42);
}

test "getNetworkStats - invalid interface" {
    var threaded: Io.Threaded = .init_single_threaded;
    try testing.expectError(
        NetworkError.InterfaceNotFound,
        getNetworkStats(threaded.io(), "nonexistent", 0),
    );
}

test "parseWirelessStats" {
    const content =
        \\Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE
        \\ face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22
        \\ wlp3s0: 0000   56.  -54.  -256.        0      0      0      0      0        0
        \\
    ;
    var info = WifiInfo{};
    parseWirelessStats(content, "wlp3s0", &info);
    try testing.expect(info.is_wireless);
    try testing.expectEqual(@as(u8, 80), info.signal_strength);
    try testing.expectEqual(@as(?i32, -54), info.signal_dbm);

    var info_eth = WifiInfo{};
    parseWirelessStats(content, "enp4s0", &info_eth);
    try testing.expect(!info_eth.is_wireless);
}
