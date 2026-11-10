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

pub const NetworkError = @import("NetworkError.zig").NetworkError;
pub const Header = @import("Header.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const IpAddress = Io.net.IpAddress;

pub const DNS_PORT: u16 = 53;
pub const DNS_TYPE_A: u16 = 1;
pub const DNS_CLASS_IN: u16 = 1;

const FALLBACK_DNS = [_][]const u8{ "9.9.9.9", "1.1.1.1" };

/// Reads DNS servers from /etc/resolv.conf.
/// Returns a slice of server IP strings. Caller must free each string and the slice.
pub fn getSystemDnsServers(io: Io, allocator: Allocator) ![][]const u8 {
    var file = Dir.openFileAbsolute(io, "/etc/resolv.conf", .{ .mode = .read_only }) catch return try getFallbackServers(allocator);
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &.{});
    const bytes_read = reader.interface.readSliceShort(&buffer) catch return try getFallbackServers(allocator);

    return parseResolvConf(allocator, buffer[0..bytes_read]) catch return try getFallbackServers(allocator);
}

fn getFallbackServers(allocator: Allocator) ![][]const u8 {
    var servers = try allocator.alloc([]const u8, FALLBACK_DNS.len);
    for (FALLBACK_DNS, 0..) |server, i| servers[i] = try allocator.dupe(u8, server);
    return servers;
}

fn parseResolvConf(allocator: Allocator, content: []const u8) ![][]const u8 {
    var servers: ArrayList([]const u8) = .empty;
    errdefer {
        for (servers.items) |s| allocator.free(s);
        servers.deinit(allocator);
    }

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

        if (mem.startsWith(u8, trimmed, "nameserver")) {
            var parts = mem.tokenizeAny(u8, trimmed, " \t");
            _ = parts.next();

            if (parts.next()) |server| {
                if (mem.findScalar(u8, server, ':') != null) continue;
                try servers.append(allocator, try allocator.dupe(u8, server));
            }
        }
    }

    if (servers.items.len == 0) return error.InvalidResponse;

    return servers.toOwnedSlice(allocator);
}

/// Frees DNS server list allocated by getSystemDnsServers.
pub fn freeDnsServers(allocator: Allocator, servers: [][]const u8) void {
    for (servers) |s| allocator.free(s);
    allocator.free(servers);
}

/// Encode domain name into DNS wire format.
pub fn encodeDomain(domain: []const u8, buffer: []u8) !usize {
    var pos: usize = 0;
    var labels = mem.splitScalar(u8, domain, '.');

    while (labels.next()) |label| {
        if (label.len == 0) continue;
        if (label.len > 63) return NetworkError.LabelTooLong;
        if (pos + 1 + label.len >= buffer.len) return NetworkError.BufferTooSmall;

        buffer[pos] = @intCast(label.len);
        @memcpy(buffer[pos + 1 ..][0..label.len], label);
        pos += 1 + label.len;
    }

    if (pos >= buffer.len) return NetworkError.BufferTooSmall;
    buffer[pos] = 0;
    return pos + 1;
}

/// Build DNS query packet.
pub fn buildQuery(allocator: Allocator, domain: []const u8, query_id: u16) ![]u8 {
    var buffer = try allocator.alloc(u8, 512);
    errdefer allocator.free(buffer);

    const header: Header = .{
        .id = query_id,
        .flags = 0x0100,
        .qdcount = 1,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };

    @memcpy(buffer[0..12], &header.toBytes());

    var pos: usize = 12;
    pos += try encodeDomain(domain, buffer[pos..]);

    mem.writeInt(u16, buffer[pos..][0..2], DNS_TYPE_A, .big);
    mem.writeInt(u16, buffer[pos + 2 ..][0..2], DNS_CLASS_IN, .big);
    pos += 4;

    return try allocator.realloc(buffer, pos);
}

/// Parse domain name from DNS response (handles compression).
pub fn parseDomain(response: []const u8, start_pos: usize, name_buf: []u8) !struct { name_len: usize, bytes_read: usize } {
    var pos = start_pos;
    var name_pos: usize = 0;
    var jumped = false;
    var jump_pos = start_pos;

    while (pos < response.len) {
        const len = response[pos];

        if ((len & 0xC0) == 0xC0) {
            if (!jumped) jump_pos = pos + 2;
            jumped = true;
            if (pos + 1 >= response.len) return NetworkError.InvalidCompression;
            pos = (@as(u16, len & 0x3F) << 8) | response[pos + 1];
            continue;
        }

        if (len == 0) {
            if (!jumped) jump_pos = pos + 1;
            break;
        }

        if (name_pos > 0) {
            if (name_pos >= name_buf.len) return NetworkError.NameTooLong;
            name_buf[name_pos] = '.';
            name_pos += 1;
        }

        pos += 1;
        if (pos + len > response.len) return NetworkError.InvalidLabel;
        if (name_pos + len > name_buf.len) return NetworkError.NameTooLong;

        @memcpy(name_buf[name_pos..][0..len], response[pos..][0..len]);
        name_pos += len;
        pos += len;
    }

    return .{ .name_len = name_pos, .bytes_read = jump_pos - start_pos };
}

/// Extract first IPv4 address from DNS response.
pub fn parseRecord(response: []const u8) !?[4]u8 {
    if (response.len < 12) return NetworkError.ResponseTooSmall;

    const header: Header = .fromBytes(response[0..12]);
    if (header.ancount == 0) return null;

    var pos: usize = 12;
    var name_buf: [256]u8 = undefined;

    pos += (try parseDomain(response, pos, &name_buf)).bytes_read;
    if (pos + 4 > response.len) return NetworkError.InvalidResponse;
    pos += 4;

    for (0..header.ancount) |_| {
        pos += (try parseDomain(response, pos, &name_buf)).bytes_read;
        if (pos + 10 > response.len) return NetworkError.InvalidResponse;

        const record_type = mem.readInt(u16, response[pos..][0..2], .big);
        const data_len = mem.readInt(u16, response[pos + 8 ..][0..2], .big);
        pos += 10;

        if (record_type == DNS_TYPE_A and data_len == 4) {
            if (pos + 4 > response.len) return NetworkError.InvalidResponse;
            return response[pos..][0..4].*;
        }

        pos += data_len;
        if (pos > response.len) return NetworkError.InvalidResponse;
    }

    return null;
}

/// Resolves domain to IPv4 address using system DNS servers.
/// Caller owns returned string.
pub fn resolveIP(io: Io, allocator: Allocator, domain: []const u8) !?[]const u8 {
    const servers = try getSystemDnsServers(io, allocator);
    defer freeDnsServers(allocator, servers);

    var rand_bytes: [2]u8 = undefined;
    Io.random(io, &rand_bytes);
    const query_id = mem.readInt(u16, &rand_bytes, .native);

    const query = try buildQuery(allocator, domain, query_id);
    defer allocator.free(query);

    const local_addr = IpAddress.parseIp4("0.0.0.0", 0) catch return null;

    for (servers) |server| {
        const dns_addr = IpAddress.parseIp4(server, DNS_PORT) catch continue;

        const socket = local_addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch continue;
        defer socket.close(io);

        _ = socket.send(io, &dns_addr, query) catch continue;

        var response: [512]u8 = undefined;
        const msg = socket.receive(io, &response) catch continue;

        if (parseRecord(response[0..msg.data.len])) |maybe_ip| {
            if (maybe_ip) |ip| {
                return try allocator.print("{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
            }
        } else |_| continue;
    }

    return null;
}

/// Creates an ICMP Echo Request packet.
pub inline fn createIcmpPacket(buffer: []u8) void {
    @memset(buffer, 0);
    buffer[0] = 8;
    buffer[1] = 0;
    mem.writeInt(u16, buffer[2..4], calculateChecksum(buffer), .big);
}

/// Calculates Internet checksum (RFC 1071).
pub inline fn calculateChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        sum +%= (@as(u32, data[i]) << 8) | data[i + 1];
    }

    if (i < data.len) sum +%= @as(u32, data[i]) << 8;

    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);

    return ~@as(u16, @truncate(sum));
}

const testing = std.testing;

test "encodeDomain" {
    var buf: [256]u8 = undefined;

    const len = try encodeDomain("example.com", &buf);
    try testing.expectEqual(@as(usize, 13), len);
    try testing.expectEqualSlices(u8, &[_]u8{ 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0 }, buf[0..len]);
}

test "encodeDomain - subdomain" {
    var buf: [256]u8 = undefined;

    const len = try encodeDomain("www.example.com", &buf);
    try testing.expectEqual(@as(usize, 17), len);
}

test "Header toBytes/fromBytes roundtrip" {
    const header: Header = .{
        .id = 0x1234,
        .flags = 0x0100,
        .qdcount = 1,
        .ancount = 2,
        .nscount = 3,
        .arcount = 4,
    };

    const bytes = header.toBytes();
    const parsed: Header = .fromBytes(&bytes);

    try testing.expectEqual(header.id, parsed.id);
    try testing.expectEqual(header.flags, parsed.flags);
    try testing.expectEqual(header.ancount, parsed.ancount);
}

test "parseResolvConf" {
    const content =
        \\# This is a comment
        \\nameserver 192.168.1.1
        \\nameserver 8.8.8.8
        \\; another comment
        \\nameserver ::1
        \\search local
    ;

    const servers = try parseResolvConf(testing.allocator, content);
    defer freeDnsServers(testing.allocator, servers);

    try testing.expectEqual(@as(usize, 2), servers.len);
    try testing.expectEqualStrings("192.168.1.1", servers[0]);
    try testing.expectEqualStrings("8.8.8.8", servers[1]);
}

test "calculateChecksum" {
    const data = [_]u8{ 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01 };
    const checksum = calculateChecksum(&data);
    try testing.expect(checksum != 0);
}
