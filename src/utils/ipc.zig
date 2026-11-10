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
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const posix = std.posix;
const sockaddr_un = posix.sockaddr.un;
const env = @import("env.zig");

/// Returns the default UNIX domain socket path for vergebar IPC.
pub fn getVergebarSocketPath(buf: []u8) ![]const u8 {
    if (env.get("XDG_RUNTIME_DIR")) |xdg| {
        return mem.print(buf, "{s}/vergebar.sock", .{xdg});
    }
    const uid = posix.system.getuid();
    return mem.print(buf, "/tmp/vergebar-{d}.sock", .{uid});
}

/// Creates a non-blocking UNIX domain socket server listening for vergebar IPC.
pub fn createIpcServer(socket_path: []const u8) !posix.fd_t {
    var path_buf: [108]u8 = undefined;
    if (socket_path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..socket_path.len], socket_path);
    path_buf[socket_path.len] = 0;

    _ = posix.system.unlink(@ptrCast(&path_buf));

    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) return error.SocketCreationFailed;
    const fd: posix.fd_t = @intCast(rc);
    errdefer _ = posix.system.close(fd);

    var addr: sockaddr_un = mem.zeroes(sockaddr_un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    const bind_rc = posix.system.bind(fd, @ptrCast(&addr), @sizeOf(sockaddr_un));
    if (posix.errno(bind_rc) != .SUCCESS) return error.BindFailed;

    const listen_rc = posix.system.listen(fd, 16);
    if (posix.errno(listen_rc) != .SUCCESS) return error.ListenFailed;

    return fd;
}

/// Connects to the running vergebar IPC server, delivers `cmd`, and returns the response slice.
pub fn sendClientCommand(allocator: Allocator, cmd: []const u8) ![]u8 {
    var path_buf: [256]u8 = undefined;
    const sock_path = try getVergebarSocketPath(&path_buf);

    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) return error.SocketCreationFailed;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = posix.system.close(fd);

    var addr: sockaddr_un = mem.zeroes(sockaddr_un);
    addr.family = posix.AF.UNIX;
    if (sock_path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..sock_path.len], sock_path);
    addr.path[sock_path.len] = 0;

    const conn_rc = posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un));
    if (posix.errno(conn_rc) != .SUCCESS) return error.ConnectionRefused;

    if (posix.system.write(fd, @ptrCast(cmd.ptr), cmd.len) < 0) return error.WriteFailed;
    if (posix.system.write(fd, "\n", 1) < 0) return error.WriteFailed;

    var resp: ArrayList(u8) = .empty;
    errdefer resp.deinit(allocator);

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) break;
        try resp.appendSlice(allocator, buf[0..n]);
    }

    return resp.toOwnedSlice(allocator);
}

/// Query Hyprland UNIX socket and return the response slice allocated on `allocator`.
pub fn queryHyprlandSocket(allocator: Allocator, cmd: []const u8) ?[]u8 {
    const xdg = env.get("XDG_RUNTIME_DIR") orelse return null;
    const sig = env.get("HYPRLAND_INSTANCE_SIGNATURE") orelse return null;

    var path_buf: [108]u8 = undefined;
    const sock_path = mem.print(&path_buf, "{s}/hypr/{s}/.socket.sock", .{ xdg, sig }) catch return null;

    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = posix.system.close(fd);

    var addr: sockaddr_un = mem.zeroes(sockaddr_un);
    addr.family = posix.AF.UNIX;
    if (sock_path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..sock_path.len], sock_path);
    addr.path[sock_path.len] = 0;

    if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) return null;

    if (posix.system.write(fd, @ptrCast(cmd.ptr), cmd.len) < 0) return null;

    var resp: ArrayList(u8) = .empty;
    errdefer resp.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        resp.appendSlice(allocator, buf[0..n]) catch break;
    }

    if (resp.items.len == 0) {
        resp.deinit(allocator);
        return null;
    }
    return resp.toOwnedSlice(allocator) catch null;
}

/// Connects to Hyprland's `.socket2.sock` event stream in non-blocking mode.
pub fn connectHyprlandEventSocket() ?posix.fd_t {
    const xdg = env.get("XDG_RUNTIME_DIR") orelse return null;
    const sig = env.get("HYPRLAND_INSTANCE_SIGNATURE") orelse return null;

    var path_buf: [108]u8 = undefined;
    const sock_path = mem.print(&path_buf, "{s}/hypr/{s}/.socket2.sock", .{ xdg, sig }) catch return null;

    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: posix.fd_t = @intCast(rc);

    var addr: sockaddr_un = mem.zeroes(sockaddr_un);
    addr.family = posix.AF.UNIX;
    if (sock_path.len >= addr.path.len) {
        _ = posix.system.close(fd);
        return null;
    }
    @memcpy(addr.path[0..sock_path.len], sock_path);
    addr.path[sock_path.len] = 0;

    if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) {
        _ = posix.system.close(fd);
        return null;
    }

    const O_NONBLOCK: usize = 0x800;
    _ = posix.system.fcntl(fd, posix.F.SETFL, O_NONBLOCK);
    return fd;
}

/// Connects to Sway/i3 IPC socket, subscribes to the given event list (e.g. `["workspace", "window"]`),
/// and returns the non-blocking file descriptor ready for event polling/reading.
pub fn connectSwayEventSocket(payload: []const u8) ?posix.fd_t {
    const sock_path = env.get("SWAYSOCK") orelse env.get("I3SOCK") orelse return null;

    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: posix.fd_t = @intCast(rc);

    var addr: sockaddr_un = mem.zeroes(sockaddr_un);
    addr.family = posix.AF.UNIX;
    if (sock_path.len >= addr.path.len) {
        _ = posix.system.close(fd);
        return null;
    }
    @memcpy(addr.path[0..sock_path.len], sock_path);
    addr.path[sock_path.len] = 0;

    if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) {
        _ = posix.system.close(fd);
        return null;
    }

    var header: [14]u8 = undefined;
    @memcpy(header[0..6], "i3-ipc");
    mem.writeInt(u32, header[6..10], @intCast(payload.len), .little);
    mem.writeInt(u32, header[10..14], 2, .little); // 2 = IPC_SUBSCRIBE

    if (posix.system.write(fd, @ptrCast(&header), header.len) < 0 or
        posix.system.write(fd, @ptrCast(payload.ptr), payload.len) < 0)
    {
        _ = posix.system.close(fd);
        return null;
    }

    const O_NONBLOCK: usize = 0x800;
    _ = posix.system.fcntl(fd, posix.F.SETFL, O_NONBLOCK);
    return fd;
}

/// Query Sway / i3 UNIX socket and return response slice allocated on `allocator`.
pub fn querySwaySocket(allocator: Allocator, msg_type: u32, payload: []const u8) ?[]u8 {
    const sock_path = env.get("SWAYSOCK") orelse env.get("I3SOCK") orelse return null;

    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = posix.system.close(fd);

    var addr: sockaddr_un = mem.zeroes(sockaddr_un);
    addr.family = posix.AF.UNIX;
    if (sock_path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..sock_path.len], sock_path);
    addr.path[sock_path.len] = 0;

    if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) return null;

    var header: [14]u8 = undefined;
    @memcpy(header[0..6], "i3-ipc");
    mem.writeInt(u32, header[6..10], @intCast(payload.len), .little);
    mem.writeInt(u32, header[10..14], msg_type, .little);

    if (posix.system.write(fd, @ptrCast(&header), header.len) < 0) return null;
    if (payload.len > 0) {
        if (posix.system.write(fd, @ptrCast(payload.ptr), payload.len) < 0) return null;
    }

    var resp_hdr: [14]u8 = undefined;
    var hdr_read: usize = 0;
    while (hdr_read < 14) {
        const n = posix.read(fd, resp_hdr[hdr_read..]) catch break;
        if (n == 0) break;
        hdr_read += n;
    }
    if (hdr_read < 14) return null;

    const resp_len = mem.readInt(u32, resp_hdr[6..10], .little);
    if (resp_len > 10 * 1024 * 1024) return null;

    const resp_buf = allocator.alloc(u8, resp_len) catch return null;
    errdefer allocator.free(resp_buf);

    var body_read: usize = 0;
    while (body_read < resp_len) {
        const n = posix.read(fd, resp_buf[body_read..]) catch break;
        if (n == 0) break;
        body_read += n;
    }
    if (body_read < resp_len) return null;

    return resp_buf;
}

/// Query Niri UNIX socket and return the response slice allocated on `allocator`.
pub fn queryNiriSocket(allocator: Allocator, request_json: []const u8) ?[]u8 {
    const sock_path = env.get("NIRI_SOCKET") orelse return null;

    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = posix.system.close(fd);

    var addr: sockaddr_un = mem.zeroes(sockaddr_un);
    addr.family = posix.AF.UNIX;
    if (sock_path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..sock_path.len], sock_path);
    addr.path[sock_path.len] = 0;

    if (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un))) != .SUCCESS) return null;

    if (posix.system.write(fd, @ptrCast(request_json.ptr), request_json.len) < 0) return null;

    var resp: ArrayList(u8) = .empty;
    errdefer resp.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        resp.appendSlice(allocator, buf[0..n]) catch break;
    }

    if (resp.items.len == 0) {
        resp.deinit(allocator);
        return null;
    }
    return resp.toOwnedSlice(allocator) catch null;
}

test "getVergebarSocketPath format" {
    var buf: [256]u8 = undefined;
    const p = try getVergebarSocketPath(&buf);
    try std.testing.expect(p.len > 0);
    try std.testing.expect(mem.endsWith(u8, p, ".sock"));
}
