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

const UpdateInfo = @import("UpdateInfo.zig");

const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;

pub const PackageManager = enum {
    pacman,
    yay,
    paru,
    apt,
    dnf,
    zypper,
    xbps,
    flatpak,

    pub fn name(self: PackageManager) []const u8 {
        return @tagName(self);
    }

    /// Populates a provided scratch buffer to avoid dynamic allocation for argv.
    pub fn buildArgv(self: PackageManager, buffer: *[4][]const u8, pacman_db: ?[]const u8) []const []const u8 {
        switch (self) {
            .apt => {
                buffer[0..3].* = .{ "apt", "list", "--upgradable" };
                return buffer[0..3];
            },
            .dnf => {
                buffer[0..4].* = .{ "dnf", "check-upgrade", "--refresh", "-yq" };
                return buffer[0..4];
            },
            .pacman => {
                if (pacman_db) |db| {
                    buffer[0..4].* = .{ "pacman", "-Qu", "--dbpath", db };
                    return buffer[0..4];
                }
                buffer[0..2].* = .{ "pacman", "-Qu" };
                return buffer[0..2];
            },
            .yay => {
                buffer[0..2].* = .{ "yay", "-Qua" };
                return buffer[0..2];
            },
            .paru => {
                buffer[0..2].* = .{ "paru", "-Qua" };
                return buffer[0..2];
            },
            .zypper => {
                buffer[0..3].* = .{ "zypper", "--non-interactive", "lu" };
                return buffer[0..3];
            },
            .xbps => {
                buffer[0..4].* = .{ "xbps-install", "--dry-run", "--sync", "--update" };
                return buffer[0..4];
            },
            .flatpak => {
                buffer[0..4].* = .{ "flatpak", "remote-ls", "--updates", "--columns=application,version" };
                return buffer[0..4];
            },
        }
    }

    /// Parses a single line of package manager output, returning an UpdateInfo
    /// containing slices that point directly to the original line buffer.
    pub fn parseLine(self: PackageManager, line: []const u8) ?UpdateInfo {
        const trimmed = mem.trim(u8, line, &ascii.whitespace);
        if (trimmed.len == 0) return null;

        var pkg_name: []const u8 = "";
        var new_version: []const u8 = "";

        switch (self) {
            .apt => {
                const slash_idx = mem.findScalar(u8, trimmed, '/') orelse return null;
                pkg_name = trimmed[0..slash_idx];

                var parts_iter = mem.splitScalar(u8, trimmed, ' ');
                _ = parts_iter.next() orelse return null;
                new_version = parts_iter.next() orelse return null;
            },
            .dnf => {
                var parts = mem.tokenizeAny(u8, trimmed, " \t");
                const pkg_name_full = parts.next() orelse return null;
                new_version = parts.next() orelse return null;

                const dot_idx = mem.findScalarLast(u8, pkg_name_full, '.') orelse pkg_name_full.len;
                pkg_name = pkg_name_full[0..dot_idx];
            },
            .pacman, .yay, .paru => {
                const arrow_idx = mem.find(u8, trimmed, "->") orelse return null;
                const left_part = mem.trim(u8, trimmed[0..arrow_idx], &ascii.whitespace);
                new_version = mem.trim(u8, trimmed[arrow_idx + 2 ..], &ascii.whitespace);

                const last_space = mem.findScalarLast(u8, left_part, ' ') orelse return null;
                pkg_name = left_part[0..last_space];
            },
            .flatpak => {
                var it = mem.tokenizeAny(u8, trimmed, " \t");
                pkg_name = it.next() orelse return null;
                new_version = it.next() orelse return null;
            },
            .zypper => {
                if (trimmed[0] == '-' or ascii.startsWithIgnoreCase(trimmed, "S |")) return null;

                var parts_iter = mem.splitScalar(u8, trimmed, '|');
                _ = parts_iter.next();
                _ = parts_iter.next();
                const name_raw = parts_iter.next() orelse return null;
                _ = parts_iter.next() orelse return null;
                const available_raw = parts_iter.next() orelse return null;

                pkg_name = mem.trim(u8, name_raw, &ascii.whitespace);
                new_version = mem.trim(u8, available_raw, &ascii.whitespace);
            },
            .xbps => {
                var it = mem.tokenizeAny(u8, trimmed, " \t");
                const first = it.next() orelse return null;
                const second = it.next() orelse return null;

                if (!mem.eql(u8, second, "update")) return null;

                const hyphen_idx = mem.findScalarLast(u8, first, '-') orelse return null;
                const raw_name = first[0..hyphen_idx];
                const old_version = mem.trim(u8, first[hyphen_idx + 1 ..], &ascii.whitespace);

                pkg_name = mem.trim(u8, raw_name, &ascii.whitespace);

                if (it.next()) |candidate| {
                    new_version = if (ascii.isDigit(candidate[0])) candidate else old_version;
                } else {
                    new_version = old_version;
                }
            },
        }

        if (pkg_name.len == 0 or new_version.len == 0) return null;

        return .{ .pkg_name = pkg_name, .new_version = new_version };
    }
};
