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

const Updates = @This();

pub const UpdatesError = @import("UpdatesError.zig").UpdatesError;
pub const UpdateInfo = @import("UpdateInfo.zig");
pub const PackageManager = @import("PackageManager.zig").PackageManager;

const std = @import("std");
const uProcess = @import("utils").Process;
const findExecutable = uProcess.findExecutable;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const mem = std.mem;
const meta = std.meta;
const process = std.process;
const Child = process.Child;
const Environ = process.Environ;
const Map = Environ.Map;

const DEFAULT_PACMAN_DB = "/var/lib/pacman/";

io: Io,
environ_map: *Map,
allocator: Allocator,
manager: PackageManager,
updates: ArrayList(UpdateInfo) = .empty,
raw_output: ?[]u8 = null,
count: usize = 0,

pub inline fn init(io: Io, allocator: Allocator, environ_map: *Map, manager: PackageManager) Updates {
    return .{ .io = io, .environ_map = environ_map, .allocator = allocator, .manager = manager };
}

pub fn deinit(self: *Updates) void {
    self.updates.deinit(self.allocator);
    if (self.raw_output) |out| self.allocator.free(out);
}

pub fn clear(self: *Updates) void {
    self.updates.clearRetainingCapacity();
}

/// Detects and returns the first available package manager.
pub fn getManager(io: Io, allocator: Allocator, environ_map: *Map) !PackageManager {
    inline for (meta.tags(PackageManager)) |manager| {
        if (try findExecutable(io, allocator, environ_map, manager.name())) |path| {
            allocator.free(path);
            return manager;
        }
    }
    return UpdatesError.NoSupportedManager;
}

/// Checks for updates
pub fn check(self: *Updates) !void {
    if (self.raw_output) |out| {
        self.allocator.free(out);
        self.raw_output = null;
    }

    const output = try self.fetchUpdates();
    if (output.len == 0) {
        self.allocator.free(output);
        self.count = 0;
        return;
    }

    self.raw_output = output;
    try self.parseUpdates(output);
    self.count = self.updates.items.len;
}

/// Parses raw command output and appends results.
pub fn parseUpdates(self: *Updates, output: []const u8) !void {
    var lines = mem.splitScalar(u8, output, '\n');
    var skip_count: usize = if (self.manager == .zypper) 2 else 0;

    while (lines.next()) |line| {
        if (skip_count > 0) {
            skip_count -= 1;
            continue;
        }

        if (line.len == 0) continue;
        if (self.manager == .dnf and ascii.startsWithIgnoreCase(line, "Obsoleting packages")) break;

        if (self.manager.parseLine(line)) |info| {
            try self.updates.append(self.allocator, info);
        }
    }
}

fn fetchUpdates(self: Updates) ![]u8 {
    var pacman_db: ?[]u8 = null;
    defer if (pacman_db) |db| self.allocator.free(db);

    if (self.manager == .pacman) pacman_db = try self.setupPacmanDatabase();

    var arg_buffer: [4][]const u8 = undefined;
    const child_argv = self.manager.buildArgv(&arg_buffer, pacman_db);

    var child = try process.spawn(self.io, .{ .argv = child_argv, .stdout = .pipe, .stderr = .ignore });

    const stdout = try uProcess.readAll(self.io, self.allocator, child.stdout.?);
    errdefer self.allocator.free(stdout);

    const term = try child.wait(self.io);
    if (term != .exited) {
        self.allocator.free(stdout);
        return try self.allocator.alloc(u8, 0);
    }

    return stdout;
}

fn setupPacmanDatabase(self: Updates) ![]u8 {
    const db_path = try self.getCheckupPath();
    errdefer self.allocator.free(db_path);

    const pacman_db = try self.getPacmanDatabasePath();
    defer self.allocator.free(pacman_db);

    try createDirectory(self.io, db_path);
    try deleteLockFile(self.io, self.allocator, db_path);
    try createLocalSymlink(self.io, self.allocator, db_path, pacman_db);

    const status = try uProcess.runCommand(self.io, &.{ "fakeroot", "pacman", "-Sy", "--disable-sandbox", "--dbpath", db_path, "--logfile", "/dev/null" });
    if (status != 0) return UpdatesError.CannotFetchUpdates;

    return db_path;
}

fn getCheckupPath(self: Updates) ![]u8 {
    if (self.environ_map.get("CHECKUPDATES_DB")) |path| {
        return try self.allocator.dupe(u8, path);
    }

    const runtime_dir = self.environ_map.get("XDG_RUNTIME_DIR") orelse "/run/user/1000";
    return try self.allocator.print("{s}/zwc-updates-check", .{runtime_dir});
}

fn getPacmanDatabasePath(self: Updates) ![]const u8 {
    var child = process.spawn(self.io, .{
        .argv = &.{ "pacman-conf", "DBPath" },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return try self.allocator.dupe(u8, DEFAULT_PACMAN_DB);

    const stdout = uProcess.readAll(self.io, self.allocator, child.stdout.?) catch {
        _ = child.wait(self.io) catch {};
        return try self.allocator.dupe(u8, DEFAULT_PACMAN_DB);
    };
    defer self.allocator.free(stdout);
    _ = child.wait(self.io) catch {};

    const trimmed = mem.trim(u8, stdout, &ascii.whitespace);
    if (trimmed.len == 0) return try self.allocator.dupe(u8, DEFAULT_PACMAN_DB);

    return try self.allocator.dupe(u8, trimmed);
}

inline fn createDirectory(io: Io, path: []const u8) !void {
    Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn deleteLockFile(io: Io, allocator: Allocator, db_path: []const u8) !void {
    const lock_path = try allocator.print("{s}/db.lck", .{db_path});
    defer allocator.free(lock_path);

    Dir.deleteFileAbsolute(io, lock_path) catch {};
}

fn createLocalSymlink(io: Io, allocator: Allocator, db_path: []const u8, pacman_db: []const u8) !void {
    const local_path = try allocator.print("{s}/local", .{db_path});
    defer allocator.free(local_path);

    const pacman_local = try allocator.print("{s}local", .{pacman_db});
    defer allocator.free(pacman_local);

    Dir.symLinkAbsolute(io, pacman_local, local_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn testParseUpdates(allocator: Allocator, manager: PackageManager, output: []const u8) ![]UpdateInfo {
    var list: ArrayList(UpdateInfo) = .empty;
    var lines = mem.splitScalar(u8, output, '\n');
    var skip_count: usize = if (manager == .zypper) 2 else 0;

    while (lines.next()) |line| {
        if (skip_count > 0) {
            skip_count -= 1;
            continue;
        }

        if (line.len == 0) continue;
        if (manager == .dnf and ascii.startsWithIgnoreCase(line, "Obsoleting packages")) break;

        if (manager.parseLine(line)) |info| {
            try list.append(allocator, info);
        }
    }
    return list.toOwnedSlice(allocator);
}

const testing = std.testing;

test "parseUpdates apt" {
    const output =
        \\Listing... Done
        \\libacl1/testing 2.3.2-2+b2 amd64 [upgradable from: 2.3.2-2+b1]
        \\libattr1/testing 1:2.5.2-3+b1 amd64 [upgradable from: 1:2.5.2-3]
        \\libbsd0/testing 0.12.2-2+b1 amd64 [upgradable from: 0.12.2-2]
        \\libbz2-1.0/testing 1.0.8-6+b1 amd64 [upgradable from: 1.0.8-6]
        \\libgmp10/testing 2:6.3.0+dfsg-5+b1 amd64 [upgradable from: 2:6.3.0+dfsg-5]
        \\liblzma5/testing 5.8.2-2 amd64 [upgradable from: 5.8.2-1]
        \\libmd0/testing 1.1.0-2+b2 amd64 [upgradable from: 1.1.0-2+b1]
        \\libpam-modules-bin/testing 1.7.0-5+b1 amd64 [upgradable from: 1.7.0-5]
        \\libpam-modules/testing 1.7.0-5+b1 amd64 [upgradable from: 1.7.0-5]
        \\libpam0g/testing 1.7.0-5+b1 amd64 [upgradable from: 1.7.0-5]
        \\libpcre2-8-0/testing 10.46-1+b1 amd64 [upgradable from: 10.46-1]
        \\libssl3t64/testing 3.5.4-1+b1 amd64 [upgradable from: 3.5.4-1]
        \\libxxhash0/testing 0.8.3-2+b1 amd64 [upgradable from: 0.8.3-2]
        \\libzstd1/testing 1.5.7+dfsg-3+b1 amd64 [upgradable from: 1.5.7+dfsg-3]
        \\openssl-provider-legacy/testing 3.5.4-1+b1 amd64 [upgradable from: 3.5.4-1]
        \\
    ;

    const updates = try testParseUpdates(testing.allocator, .apt, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 15), updates.len);
    try testing.expectEqualStrings("libacl1", updates[0].pkg_name);
    try testing.expectEqualStrings("2.3.2-2+b2", updates[0].new_version);
    try testing.expectEqualStrings("libssl3t64", updates[11].pkg_name);
    try testing.expectEqualStrings("3.5.4-1+b1", updates[11].new_version);
}

test "parseUpdates dnf" {
    const output =
        \\coreutils.x86_64                   9.7-7.fc43        updates
        \\coreutils-common.x86_64            9.7-7.fc43        updates
        \\curl.x86_64                        8.15.0-4.fc43     updates
        \\glib2.x86_64                       2.86.3-1.fc43     updates
        \\glibc.x86_64                       2.42-5.fc43       updates
        \\glibc-common.x86_64                2.42-5.fc43       updates
        \\glibc-minimal-langpack.x86_64      2.42-5.fc43       updates
        \\gnupg2.x86_64                      2.4.9-1.fc43      updates
        \\gnupg2-dirmngr.x86_64              2.4.9-1.fc43      updates
        \\gnupg2-gpg-agent.x86_64            2.4.9-1.fc43      updates
        \\gnupg2-gpgconf.x86_64              2.4.9-1.fc43      updates
        \\Obsoleting Packages
        \\
    ;

    const updates = try testParseUpdates(testing.allocator, .dnf, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 11), updates.len);
    try testing.expectEqualStrings("coreutils", updates[0].pkg_name);
    try testing.expectEqualStrings("9.7-7.fc43", updates[0].new_version);
}

test "parseUpdates pacman" {
    const output =
        \\alsa-card-profiles 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\glibc 2.42+r47+ga1d3294a5bed-2 -> 2.42+r50+g453e6b8dbab-2
        \\lib32-glibc 2.42+r47+ga1d3294a5bed-2 -> 2.42+r50+g453e6b8dbab-2
        \\lib32-libltdl 2.6.0-1 -> 2.6.0-2
        \\lib32-libpipewire 1:1.4.9-1 -> 1:1.4.10-1
        \\lib32-mesa 1:25.3.3-5 -> 1:25.3.3-6
        \\lib32-opencl-mesa 1:25.3.3-5 -> 1:25.3.3-6
        \\lib32-pipewire 1:1.4.9-1 -> 1:1.4.10-1
        \\lib32-pipewire-jack 1:1.4.9-1 -> 1:1.4.10-1
        \\lib32-vulkan-mesa-implicit-layers 1:25.3.3-5 -> 1:25.3.3-6
        \\lib32-vulkan-radeon 1:25.3.3-5 -> 1:25.3.3-6
        \\libpipewire 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\libpng-apng 1.6.50-1 -> 1.6.54-1
        \\libtool 2.6.0-1 -> 2.6.0-2
        \\linux-cachyos 6.18.5-2 -> 6.18.6-2
        \\linux-cachyos-headers 6.18.5-2 -> 6.18.6-2
        \\mesa 1:25.3.3-5 -> 1:25.3.3-6
        \\meson 1.10.0-4 -> 1.10.1-1
        \\opencl-mesa 1:25.3.3-5 -> 1:25.3.3-6
        \\pacman 7.1.0.r7.gb9f7d4a-3 -> 7.1.0.r9.g54d9411-2
        \\pipewire 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\pipewire-alsa 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\pipewire-audio 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\pipewire-jack 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\pipewire-pulse 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\rdma-core 60.0-3.1 -> 61.0-1.1
        \\vulkan-mesa-implicit-layers 1:25.3.3-5 -> 1:25.3.3-6
        \\vulkan-radeon 1:25.3.3-5 -> 1:25.3.3-6
    ;

    const updates = try testParseUpdates(testing.allocator, .pacman, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 28), updates.len);
    try testing.expectEqualStrings("mesa", updates[16].pkg_name);
    try testing.expectEqualStrings("1:25.3.3-6", updates[16].new_version);
}

test "parseUpdates zypper" {
    const output =
        \\Loading repository data...
        \\Reading installed packages...
        \\S  | Repository                       | Name                              | Current Version                         | Available Version                       | Arch
        \\---+----------------------------------+-----------------------------------+-----------------------------------------+-----------------------------------------+-------
        \\v  | Asus Linux (OpenSUSE Tumbleweed) | asusctl                           | 6.3.0-1.suse.tw                         | 6.3.1-1.suse.tw                         | x86_64
        \\v  | Asus Linux (OpenSUSE Tumbleweed) | asusctl-rog-gui                   | 6.3.0-1.suse.tw                         | 6.3.1-1.suse.tw                         | x86_64
        \\v  | Brave Browser                    | brave-browser                     | 1.85.120-1                              | 1.86.139-1                              | x86_64
        \\v  | Visual Studio Code               | code                              | 1.108.0-1767882006.el8                  | 1.108.1-1768404278.el8                  | x86_64
        \\v  | Packman Essentials               | ffmpeg-4                          | 4.4.6-1699.10.0.5.pm.1                  | 4.4.6-1699.10.0.5.pm.2                  | x86_64
        \\v  | Packman Essentials               | gdk-pixbuf-loader-libheif         | 1.21.1-1699.4.pm.5                      | 1.21.2-1699.4.pm.1                      | x86_64
        \\v  | update-slowroll                  | kernel-default                    | 6.18.3-1.0.6.1.sr20251204               | 6.18.5-1.0.2.1.sr20260101               | x86_64
        \\v  | update-slowroll                  | kernel-default-devel              | 6.18.3-1.0.6.1.sr20251204               | 6.18.5-1.0.2.1.sr20260101               | x86_64
        \\v  | update-slowroll                  | kernel-devel                      | 6.18.3-1.0.6.1.sr20251204               | 6.18.5-1.0.2.1.sr20260101               | noarch
        \\v  | update-slowroll                  | kernel-firmware-platform          | 20251228-1.1                            | 20251228-2.0.2.1.sr20260101             | noarch
        \\v  | update-slowroll                  | kernel-macros                     | 6.18.3-1.0.6.1.sr20251204               | 6.18.5-1.0.2.1.sr20260101               | noarch
    ;

    const updates = try testParseUpdates(testing.allocator, .zypper, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 12), updates.len);
    try testing.expectEqualStrings("code", updates[4].pkg_name);
    try testing.expectEqualStrings("1.108.1-1768404278.el8", updates[4].new_version);
}

test "parseUpdates xbps" {
    const output =
        \\acl-2.3.2_1 update x86_64-musl https://repo-default.voidlinux.org/current/musl 38896 16778
        \\attr-2.5.2_2 update x86_64-musl https://repo-default.voidlinux.org/current/musl 27289 9062
        \\base-files-0.146_1 update x86_64-musl https://repo-default.voidlinux.org/current/musl 262416 62583
        \\bzip2-1.0.8_2 update x86_64-musl https://repo-default.voidlinux.org/current/musl 149991 61053
        \\ca-certificates-20250419+3.118.1_1 update x86_64-musl https://repo-default.voidlinux.org/current/musl 284296 170936
        \\coreutils-9.4_3 update x86_64-musl https://repo-default.voidlinux.org/current/musl 21814162 3504523
        \\dash-0.5.12_2 update x86_64-musl https://repo-default.voidlinux.org/current/musl 194963 87212
    ;

    const updates = try testParseUpdates(testing.allocator, .xbps, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 7), updates.len);
    try testing.expectEqualStrings("acl", updates[0].pkg_name);
    try testing.expectEqualStrings("2.3.2_1", updates[0].new_version);
    try testing.expectEqualStrings("dash", updates[6].pkg_name);
    try testing.expectEqualStrings("0.5.12_2", updates[6].new_version);
}

test "parseUpdates yay and paru" {
    const output =
        \\visual-studio-code-bin 1.96.2-1 -> 1.96.3-1
        \\spotify 1:1.2.53.440-1 -> 1:1.2.56.502-1
        \\
    ;

    const yay_updates = try testParseUpdates(testing.allocator, .yay, output);
    defer testing.allocator.free(yay_updates);

    try testing.expectEqual(@as(usize, 2), yay_updates.len);
    try testing.expectEqualStrings("visual-studio-code-bin", yay_updates[0].pkg_name);
    try testing.expectEqualStrings("1.96.3-1", yay_updates[0].new_version);
    try testing.expectEqualStrings("spotify", yay_updates[1].pkg_name);
    try testing.expectEqualStrings("1:1.2.56.502-1", yay_updates[1].new_version);

    const paru_updates = try testParseUpdates(testing.allocator, .paru, output);
    defer testing.allocator.free(paru_updates);

    try testing.expectEqual(@as(usize, 2), paru_updates.len);
    try testing.expectEqualStrings("spotify", paru_updates[1].pkg_name);
}

test "parseUpdates flatpak" {
    const output = "org.mozilla.firefox\t134.0.2\norg.signal.Signal\t7.37.0\n";

    const updates = try testParseUpdates(testing.allocator, .flatpak, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 2), updates.len);
    try testing.expectEqualStrings("org.mozilla.firefox", updates[0].pkg_name);
    try testing.expectEqualStrings("134.0.2", updates[0].new_version);
    try testing.expectEqualStrings("org.signal.Signal", updates[1].pkg_name);
    try testing.expectEqualStrings("7.37.0", updates[1].new_version);
}
