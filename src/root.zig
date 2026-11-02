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
const heap = std.heap;
const process = std.process;
const json = std.json;
const StringHashMap = std.StringHashMap;
const debug = std.debug;
const gtk = @import("gtk");
const Bar = @import("bar/bar.zig").Bar;
const config_pkg = @import("utils").Config;
const BarConfig = config_pkg.BarConfig;
const modules = @import("modules/root.zig");

const build_options = @import("build_options");
const VERSION = if (@hasDecl(build_options, "version")) build_options.version else "1.0.0";

const Context = @import("utils").Context;

var signal_pipe_read_fd: posix.fd_t = -1;
var signal_pipe_write_fd: posix.fd_t = -1;
var global_active_bars: ?*ArrayList(*Bar) = null;
var global_style_path: ?[]const u8 = null;

fn onSignalReceived(sig: posix.SIG) callconv(.c) void {
    if (signal_pipe_write_fd >= 0) {
        const sig_val: u32 = @backingInt(sig);
        _ = posix.system.write(signal_pipe_write_fd, @ptrCast(&sig_val), @sizeOf(u32));
    }
}

fn setupSignals() void {
    var pfd: [2]posix.fd_t = undefined;
    if (posix.system.pipe2(&pfd, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) return;

    signal_pipe_read_fd = pfd[0];
    signal_pipe_write_fd = pfd[1];

    var act: posix.Sigaction = mem.zeroes(posix.Sigaction);
    act.handler = .{ .handler = onSignalReceived };

    posix.sigaction(posix.SIG.USR1, &act, null);
    posix.sigaction(posix.SIG.USR2, &act, null);

    var sig: u32 = 34;
    while (sig <= 64) : (sig += 1) posix.sigaction(@fromBackingInt(@intCast(sig)), &act, null);

    _ = gtk.g_timeout_add(50, @ptrCast(&processSignals), null);
}

fn processSignals(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    _ = user_data;
    if (signal_pipe_read_fd < 0) return 1;

    var sig: u32 = 0;
    var sig_buf: [@sizeOf(u32)]u8 = undefined;
    while (posix.read(signal_pipe_read_fd, &sig_buf)) |bytes_read| {
        if (bytes_read != @sizeOf(u32)) break;
        sig = mem.bytesToValue(u32, &sig_buf);

        if (sig == @backingInt(posix.SIG.USR1)) {
            debug.print("Received SIGUSR1: toggling bar visibility\n", .{});
            if (global_active_bars) |bars| {
                for (bars.items) |b| b.toggleVisibility();
            }
        } else if (sig == @backingInt(posix.SIG.USR2)) {
            debug.print("Received SIGUSR2: reloading stylesheet\n", .{});
            @import("bar/bar.zig").loadCss(global_style_path, true);
        } else if (sig >= 34 and sig <= 64) {
            const rt_offset = sig - 34;
            debug.print("Received SIGRTMIN+{d}: dispatching to custom modules\n", .{rt_offset});
            modules.custom.dispatchSignal(@intCast(rt_offset));
        }
    } else |_| {}
    return 1;
}

const CliArgs = struct {
    config_path: ?[]const u8 = null,
    style_path: ?[]const u8 = null,
    show_help: bool = false,
    show_version: bool = false,
};

fn parseArgs(args_raw: process.Args) CliArgs {
    var it: process.Args.Iterator = .init(args_raw);
    _ = it.next();

    var result: CliArgs = .{};
    while (it.next()) |arg| {
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            result.show_help = true;
        } else if (mem.eql(u8, arg, "-v") or mem.eql(u8, arg, "--version")) {
            result.show_version = true;
        } else if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--config")) {
            if (it.next()) |val| result.config_path = val;
        } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--style")) {
            if (it.next()) |val| result.style_path = val;
        }
    }
    return result;
}

fn printHelp() void {
    const help_text =
        \\vergebar - High-performance Wayland status bar in Zig with GTK4
        \\
        \\Usage:
        \\  vergebar [options]
        \\
        \\Options:
        \\  -c, --config <path>    Path to configuration file (JSON/JSONC)
        \\  -s, --style <path>     Path to CSS stylesheet
        \\  -v, --version          Show version information
        \\  -h, --help             Show this help message
        \\
        \\Default config lookup paths:
        \\  ~/.config/vergebar/config.jsonc
        \\  ~/.config/vergebar/config.json
        \\  ~/.config/waybar/config.jsonc
        \\
        \\Default style lookup paths:
        \\  ~/.config/vergebar/style.css
        \\  ~/.config/waybar/style.css
    ;
    debug.print("{s}\n", .{help_text});
}

fn onMonitorsChanged(list: ?*gtk.GListModel, position: c_uint, removed: c_uint, added: c_uint, user_data: ?*anyopaque) callconv(.c) void {
    _ = list;
    _ = position;
    _ = removed;
    _ = added;
    _ = user_data;
    debug.print("Display monitors changed (hotplug detected)\n", .{});
}

pub fn main(init: process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const cli = parseArgs(init.minimal.args);
    if (cli.show_help) {
        printHelp();
        return;
    }

    if (cli.show_version) {
        debug.print("vergebar v{s}\n", .{VERSION});
        return;
    }

    Context.init(.{
        .io = io,
        .gpa = allocator,
        .environ_map = init.environ_map,
    });

    if (Context.getEnv("GSK_RENDERER") == null) _ = gtk.g_setenv("GSK_RENDERER", "cairo", 0);
    if (Context.getEnv("MESA_LOG_LEVEL") == null) _ = gtk.g_setenv("MESA_LOG_LEVEL", "error", 0);

    gtk.gtk_init();

    setupSignals();

    const config_path = cli.config_path orelse config_pkg.findDefaultConfigPath(allocator);
    defer if (cli.config_path == null and config_path != null) allocator.free(config_path.?);

    var configs_list: []BarConfig = &.{};
    var has_loaded_cfg = false;

    if (config_path) |cp| {
        debug.print("Loading config from: {s}\n", .{cp});
        if (config_pkg.bar_config.loadConfigsFromFile(allocator, cp)) |loaded| {
            configs_list = loaded;
            has_loaded_cfg = true;
        } else |err| {
            debug.print("Failed to load config {s}: {}, falling back to defaults\n", .{ cp, err });
        }
    }

    if (!has_loaded_cfg or configs_list.len == 0) {
        debug.print("Using built-in default bar configuration\n", .{});
        if (config_pkg.bar_config.loadConfigsFromString(allocator, config_pkg.DEFAULT_CONFIG)) |loaded| {
            configs_list = loaded;
        } else |_| {
            var arena: heap.ArenaAllocator = .init(allocator);
            const a = arena.allocator();
            const def_cfg: BarConfig = .{
                .arena = arena,
                .modules_map = StringHashMap(json.Value).init(a),
                .modules_left = try a.dupe([]const u8, &.{ "workspaces", "window" }),
                .modules_center = try a.dupe([]const u8, &.{"clock"}),
                .modules_right = try a.dupe([]const u8, &.{ "cpu", "memory", "network", "wireplumber", "tray" }),
            };

            const single = try allocator.alloc(BarConfig, 1);
            single[0] = def_cfg;
            configs_list = single;
        }
    }

    defer {
        for (configs_list) |*cfg| cfg.deinit();
        allocator.free(configs_list);
    }

    var style_path: ?[]const u8 = cli.style_path;
    var allocated_style_path: ?[]const u8 = null;
    if (style_path == null) {
        if (config_pkg.findVergebarStylePath(allocator)) |vp| {
            style_path = vp;
            allocated_style_path = vp;
        } else if (has_loaded_cfg) {
            if (config_pkg.findDefaultStylePath(allocator)) |sp| {
                style_path = sp;
                allocated_style_path = sp;
            }
        }
    }

    defer if (allocated_style_path) |p| allocator.free(p);
    global_style_path = style_path;

    if (style_path) |sp| {
        debug.print("Loading style from: {s}\n", .{sp});
    } else {
        debug.print("Using built-in default style\n", .{});
    }

    const display = gtk.gdk_display_get_default();
    const monitor_list = if (display) |d| gtk.gdk_display_get_monitors(d) else null;
    const num_monitors = if (monitor_list) |ml| gtk.g_list_model_get_n_items(ml) else 0;

    if (monitor_list) |ml| _ = gtk.g_signal_connect_data(ml, "items-changed", @ptrCast(&onMonitorsChanged), null, null, 0);

    var active_bars: ArrayList(*Bar) = .empty;
    global_active_bars = &active_bars;

    defer {
        global_active_bars = null;
        for (active_bars.items) |b| b.deinit();
        active_bars.deinit(allocator);
    }

    for (configs_list) |*cfg| {
        var spawned_for_cfg = false;

        if (num_monitors > 0 and monitor_list != null) {
            var m_idx: c_uint = 0;
            while (m_idx < num_monitors) : (m_idx += 1) {
                const mon = gtk.g_list_model_get_item(monitor_list.?, m_idx);
                const conn = gtk.gdk_monitor_get_connector(@ptrCast(mon));
                const conn_str = if (conn) |c| mem.span(c) else "";

                if (conn_str.len > 0 and cfg.matchesOutput(conn_str)) {
                    debug.print("Spawning bar for output '{s}'\n", .{conn_str});
                    const b = try Bar.create(io, allocator, cfg, @ptrCast(mon), style_path);
                    try active_bars.append(allocator, b);
                    spawned_for_cfg = true;
                }
            }
        }

        if (!spawned_for_cfg) {
            const b = try Bar.create(io, allocator, cfg, null, style_path);
            try active_bars.append(allocator, b);
        }
    }

    const loop = gtk.g_main_loop_new(null, 0);
    gtk.g_main_loop_run(loop);
}
