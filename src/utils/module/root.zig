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
const process = std.process;
const Io = std.Io;
const File = Io.File;

const ConfigLoader = @import("../config/loader.zig");
const Json = @import("../json/root.zig");
const Replacer = @import("../replacer/root.zig");
const Watcher = @import("../watcher/root.zig");

pub const RenderOptions = struct {
    percentage: ?f64 = null,
    class: ?[]const u8 = null,
    custom_text: ?[]const u8 = null,
    custom_tooltip: ?[]const u8 = null,
};

/// High-level runtime harness for Waybar modules.
///
/// Encapsulates .zon configuration loading, stdout buffering, zero-CPU signalfd
/// sleeping via Watcher, streaming Json formatting, and Replacer template rendering.
pub fn Module(comptime ConfigType: type) type {
    return struct {
        const Self = @This();

        pub const Config = ConfigType;

        gpa: Allocator,
        io: Io,
        config: ConfigType,
        config_loader: ConfigLoader,
        watcher: Watcher,
        json: Json,
        replacer: Replacer,
        stdout_buffer: []u8,
        stdout_writer: File.Writer,
        is_first_tick: bool = true,

        pub fn init(init_args: process.Init, comptime module_name: []const u8) !Self {
            const gpa = init_args.gpa;
            const io = init_args.io;

            const stdout_buffer = try gpa.alloc(u8, 4096);
            errdefer gpa.free(stdout_buffer);

            const stdout_writer = File.writer(.stdout(), io, stdout_buffer);

            var config_loader: ConfigLoader = .init(io, gpa, init_args.environ_map);
            const loaded_config: ConfigType = config_loader.load(module_name, ConfigType);

            var watcher = try Watcher.init();
            errdefer watcher.deinit();

            var json: Json = .init(gpa);
            errdefer json.deinit();

            var replacer: Replacer = .init(gpa);
            errdefer replacer.deinit();

            return .{
                .gpa = gpa,
                .io = io,
                .config = loaded_config,
                .config_loader = config_loader,
                .watcher = watcher,
                .json = json,
                .replacer = replacer,
                .stdout_buffer = stdout_buffer,
                .stdout_writer = stdout_writer,
                .is_first_tick = true,
            };
        }

        pub fn deinit(self: *Self) void {
            self.json.deinit();
            self.replacer.deinit();
            self.watcher.deinit();
            self.config_loader.free(self.config);
            self.gpa.free(self.stdout_buffer);
            self.* = undefined;
        }

        /// Advance to the next tick.
        ///
        /// On subsequent calls, sleeps for config.update_interval seconds using signalfd
        /// (waking immediately on SIGUSR1/SIGUSR2 or real-time signals).
        /// Resets JSON and Replacer builders and automatically populates common placeholders.
        /// Returns false if update_interval == 0 after the first iteration.
        pub fn tick(self: *Self) !bool {
            if (!self.is_first_tick) {
                if (comptime @hasField(ConfigType, "update_interval")) {
                    if (self.config.update_interval == 0) return false;
                    _ = self.watcher.waitSeconds(self.config.update_interval);
                } else {
                    _ = self.watcher.waitSeconds(1);
                }
            }
            self.is_first_tick = false;

            self.json.clear();
            self.replacer.clear();
            try self.replacer.addCommonPlaceholders();

            if (comptime @hasField(ConfigType, "icon")) {
                try self.replacer.addKey("icon", self.config.icon);
            }

            return true;
        }

        /// Bind a typed placeholder value.
        pub inline fn put(self: *Self, key: []const u8, value: anytype) !void {
            try self.replacer.addKeyAny(key, value);
        }

        /// Bind a string placeholder value.
        pub inline fn putString(self: *Self, key: []const u8, value: []const u8) !void {
            try self.replacer.addKey(key, value);
        }

        /// Render templates, evaluate thresholds, output JSON to stdout, and flush.
        pub fn render(self: *Self, options: RenderOptions) !void {
            if (options.custom_text) |t| {
                try self.json.set("text", t);
            } else if (comptime @hasField(ConfigType, "text")) {
                const text_rendered = try self.replacer.render(self.config.text);
                defer self.replacer.free(text_rendered);
                try self.json.set("text", text_rendered);
            }

            if (options.custom_tooltip) |tt| {
                try self.json.set("tooltip", tt);
            } else if (comptime @hasField(ConfigType, "tooltip")) {
                const tooltip_rendered = try self.replacer.render(self.config.tooltip);
                defer self.replacer.free(tooltip_rendered);
                try self.json.set("tooltip", tooltip_rendered);
            }

            if (options.percentage) |pct| {
                const pct_int: i64 = @intFromFloat(@round(pct));
                try self.json.set("percentage", pct_int);
            }

            if (options.class) |c| {
                try self.json.setClass(c);
            } else if (options.percentage) |pct| {
                if (evaluateThresholdClass(self.config, pct)) |cls| {
                    try self.json.setClass(cls);
                }
            }

            try self.json.write(&self.stdout_writer.interface);
            try self.stdout_writer.interface.flush();
        }

        /// Render an error message to stdout and flush.
        pub fn renderError(self: *Self, text: []const u8, tooltip: []const u8) !void {
            self.json.clear();
            try self.json.set("text", text);
            try self.json.set("tooltip", tooltip);
            try self.json.setClass("error");
            try self.json.write(&self.stdout_writer.interface);
            try self.stdout_writer.interface.flush();
        }

        fn evaluateThresholdClass(config: ConfigType, pct: f64) ?[]const u8 {
            const has_crit = @hasField(ConfigType, "critical_threshold");
            const has_warn = @hasField(ConfigType, "warning_threshold");

            if (comptime has_crit and has_warn) {
                if (config.critical_threshold) |crit| {
                    const c_f64: f64 = switch (@typeInfo(@TypeOf(crit))) {
                        .int, .comptime_int => @floatFromInt(crit),
                        .float, .comptime_float => @floatCast(crit),
                        .optional => |opt| if (crit) |v| switch (@typeInfo(opt.child)) {
                            .int, .comptime_int => @floatFromInt(v),
                            .float, .comptime_float => @floatCast(v),
                            else => 0.0,
                        } else 0.0,
                        else => 0.0,
                    };
                    if (pct >= c_f64) return "critical";
                }
                if (config.warning_threshold) |warn| {
                    const w_f64: f64 = switch (@typeInfo(@TypeOf(warn))) {
                        .int, .comptime_int => @floatFromInt(warn),
                        .float, .comptime_float => @floatCast(warn),
                        .optional => |opt| if (warn) |v| switch (@typeInfo(opt.child)) {
                            .int, .comptime_int => @floatFromInt(v),
                            .float, .comptime_float => @floatCast(v),
                            else => 0.0,
                        } else 0.0,
                        else => 0.0,
                    };
                    if (pct >= w_f64) return "warning";
                }
                return "normal";
            } else if (comptime has_crit) {
                if (config.critical_threshold) |crit| {
                    const c_f64: f64 = switch (@typeInfo(@TypeOf(crit))) {
                        .int, .comptime_int => @floatFromInt(crit),
                        .float, .comptime_float => @floatCast(crit),
                        .optional => |opt| if (crit) |v| switch (@typeInfo(opt.child)) {
                            .int, .comptime_int => @floatFromInt(v),
                            .float, .comptime_float => @floatCast(v),
                            else => 0.0,
                        } else 0.0,
                        else => 0.0,
                    };
                    if (pct >= c_f64) return "critical";
                }
                return "normal";
            } else if (comptime has_warn) {
                if (config.warning_threshold) |warn| {
                    const w_f64: f64 = switch (@typeInfo(@TypeOf(warn))) {
                        .int, .comptime_int => @floatFromInt(warn),
                        .float, .comptime_float => @floatCast(warn),
                        .optional => |opt| if (warn) |v| switch (@typeInfo(opt.child)) {
                            .int, .comptime_int => @floatFromInt(v),
                            .float, .comptime_float => @floatCast(v),
                            else => 0.0,
                        } else 0.0,
                        else => 0.0,
                    };
                    if (pct >= w_f64) return "warning";
                }
                return "normal";
            }
            return null;
        }
    };
}
