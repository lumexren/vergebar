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
const fmt = std.fmt;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const posix = std.posix;
const heap = std.heap;
const process = std.process;
const json = std.json;
const fs = std.fs;
const Io = std.Io;
const StringHashMap = std.StringHashMap;
const debug = std.debug;
const gtk = @import("gtk");
const Bar = @import("bar.zig");
const config_pkg = @import("utils").Config;
const BarConfig = config_pkg.BarConfig;
const modules = @import("modules/root.zig");

const build_options = @import("build_options");
const VERSION = if (@hasDecl(build_options, "version")) build_options.version else "1.0.0";

const utils = @import("utils");
const env = utils.env;

var signal_pipe_read_fd: posix.fd_t = -1;
var signal_pipe_write_fd: posix.fd_t = -1;
var signal_source_id: c_uint = 0;

const App = struct {
    io: Io,
    allocator: Allocator,
    configs_list: []BarConfig,
    active_bars: ArrayList(*Bar),
    style_path: ?[]const u8,
    config_path: ?[]const u8,
    main_loop: ?*gtk.GMainLoop = null,
    config_file_monitor: ?*gtk.GFileMonitor = null,
    reload_timer_id: u32 = 0,
    style_file_monitor: ?*gtk.GFileMonitor = null,
    style_reload_timer_id: u32 = 0,
    ipc_server_fd: posix.fd_t = -1,
    ipc_source_id: c_uint = 0,
    ipc_socket_path: ?[]const u8 = null,

    pub fn spawnBars(this: *App) void {
        for (this.active_bars.items) |b| b.deinit();
        this.active_bars.clearRetainingCapacity();

        const display = gtk.gdk_display_get_default();
        const monitor_list = if (display) |d| gtk.gdk_display_get_monitors(d) else null;
        const num_monitors = if (monitor_list) |ml| gtk.g_list_model_get_n_items(ml) else 0;

        for (this.configs_list) |*cfg| {
            var spawned_for_cfg = false;

            if (num_monitors > 0 and monitor_list != null) {
                var m_idx: c_uint = 0;
                while (m_idx < num_monitors) : (m_idx += 1) {
                    const mon = gtk.g_list_model_get_item(monitor_list.?, m_idx);
                    const conn = gtk.gdk_monitor_get_connector(@ptrCast(mon));
                    const conn_str = if (conn) |c| mem.span(c) else "";

                    if (conn_str.len > 0 and cfg.matchesOutput(conn_str)) {
                        debug.print("Spawning bar for output '{s}'\n", .{conn_str});
                        const b = Bar.create(this.io, this.allocator, cfg, @ptrCast(mon), this.style_path) catch |err| {
                            debug.print("Failed to spawn bar for '{s}': {}\n", .{ conn_str, err });
                            continue;
                        };
                        this.active_bars.append(this.allocator, b) catch {};
                        spawned_for_cfg = true;
                    }
                }
            }

            if (!spawned_for_cfg) {
                const b = Bar.create(this.io, this.allocator, cfg, null, this.style_path) catch |err| {
                    debug.print("Failed to spawn default bar: {}\n", .{err});
                    continue;
                };
                this.active_bars.append(this.allocator, b) catch {};
            }
        }
    }

    pub fn reloadConfig(this: *App) void {
        const cp = this.config_path orelse return;
        debug.print("Config file changed on disk ({s}), reloading...\n", .{cp});

        const new_configs = config_pkg.loadConfigsFromFile(this.io, this.allocator, cp) catch |err| {
            debug.print("Failed to reload config file: {}, keeping current configuration\n", .{err});
            return;
        };

        if (new_configs.len == 0) {
            debug.print("Reloaded config produced 0 bar configurations; skipping reload\n", .{});
            return;
        }

        for (this.configs_list) |*cfg| cfg.deinit();
        this.allocator.free(this.configs_list);

        this.configs_list = new_configs;
        this.spawnBars();
        debug.print("Vergebar successfully reloaded with {d} bar configuration(s)\n", .{this.configs_list.len});
    }

    pub fn deinit(this: *App) void {
        if (this.reload_timer_id != 0) {
            _ = gtk.g_source_remove(this.reload_timer_id);
            this.reload_timer_id = 0;
        }
        if (this.style_reload_timer_id != 0) {
            _ = gtk.g_source_remove(this.style_reload_timer_id);
            this.style_reload_timer_id = 0;
        }
        if (this.config_file_monitor) |mon| {
            _ = gtk.g_file_monitor_cancel(mon);
            gtk.g_object_unref(mon);
            this.config_file_monitor = null;
        }
        if (this.style_file_monitor) |mon| {
            _ = gtk.g_file_monitor_cancel(mon);
            gtk.g_object_unref(mon);
            this.style_file_monitor = null;
        }
        if (this.ipc_source_id != 0) {
            _ = gtk.g_source_remove(this.ipc_source_id);
            this.ipc_source_id = 0;
        }
        if (this.ipc_server_fd >= 0) {
            _ = posix.system.close(this.ipc_server_fd);
            this.ipc_server_fd = -1;
        }
        if (this.ipc_socket_path) |sp| {
            var path_z: [108]u8 = undefined;
            if (sp.len < path_z.len) {
                @memcpy(path_z[0..sp.len], sp);
                path_z[sp.len] = 0;
                _ = posix.system.unlink(@ptrCast(&path_z));
            }
            this.allocator.free(sp);
            this.ipc_socket_path = null;
        }
        for (this.active_bars.items) |b| b.deinit();
        this.active_bars.deinit(this.allocator);
        for (this.configs_list) |*cfg| cfg.deinit();
        this.allocator.free(this.configs_list);
    }
};

fn onSignalReceived(sig: posix.SIG) callconv(.c) void {
    if (signal_pipe_write_fd >= 0) {
        const sig_val: u32 = @backingInt(sig);
        _ = posix.system.write(signal_pipe_write_fd, @ptrCast(&sig_val), @sizeOf(u32));
    }
}

fn onSignalPipeReadable(fd: c_int, condition: gtk.GIOCondition, user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    _ = fd;
    _ = condition;
    const app: *App = @ptrCast(@alignCast(user_data orelse return 0));
    return processSignals(app);
}

fn onIpcSocketAccept(fd: c_int, condition: gtk.GIOCondition, user_data: gtk.gpointer) callconv(.c) gtk.gboolean {
    _ = condition;
    const app: *App = @ptrCast(@alignCast(user_data orelse return 0));
    const listen_fd: posix.fd_t = @intCast(fd);

    var client_addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    const accept_rc = posix.system.accept(listen_fd, &client_addr, &addr_len);
    if (posix.errno(accept_rc) != .SUCCESS) return 1;
    const client_fd: posix.fd_t = @intCast(accept_rc);
    defer _ = posix.system.close(client_fd);

    var buf: [512]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch return 1;
    if (n == 0) return 1;

    const raw_cmd = mem.trim(u8, buf[0..n], " \t\r\n");
    handleIpcCommand(app, client_fd, raw_cmd);
    return 1;
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) void {
    if (bytes.len == 0) return;
    _ = posix.system.write(fd, @ptrCast(bytes.ptr), bytes.len);
}

fn handleIpcCommand(app: *App, client_fd: posix.fd_t, cmd: []const u8) void {
    if (mem.eql(u8, cmd, "toggle")) {
        for (app.active_bars.items) |b| b.toggleVisibility();
        writeAllFd(client_fd, "ok\n");
    } else if (mem.startsWith(u8, cmd, "toggle ")) {
        const target_name = mem.trim(u8, cmd[7..], " \t");
        var found = false;
        for (app.active_bars.items) |b| {
            if (b.name) |bn| {
                if (mem.eql(u8, bn, target_name)) {
                    b.toggleVisibility();
                    found = true;
                }
            }
        }
        if (found) {
            writeAllFd(client_fd, "ok\n");
        } else {
            writeAllFd(client_fd, "error: bar not found\n");
        }
    } else if (mem.eql(u8, cmd, "hide")) {
        for (app.active_bars.items) |b| {
            if (b.window) |w| gtk.gtk_widget_set_visible(w, 0);
        }
        writeAllFd(client_fd, "ok\n");
    } else if (mem.eql(u8, cmd, "show")) {
        for (app.active_bars.items) |b| {
            if (b.window) |w| gtk.gtk_widget_set_visible(w, 1);
        }
        writeAllFd(client_fd, "ok\n");
    } else if (mem.eql(u8, cmd, "reload")) {
        app.reloadConfig();
        @import("bar.zig").loadCss(app.style_path, true);
        writeAllFd(client_fd, "ok\n");
    } else if (mem.eql(u8, cmd, "reload-config")) {
        app.reloadConfig();
        writeAllFd(client_fd, "ok\n");
    } else if (mem.eql(u8, cmd, "reload-style")) {
        @import("bar.zig").loadCss(app.style_path, true);
        writeAllFd(client_fd, "ok\n");
    } else if (mem.startsWith(u8, cmd, "signal ")) {
        const sig_str = mem.trim(u8, cmd[7..], " \t");
        if (fmt.parseInt(u32, sig_str, 10)) |num| {
            modules.CustomModule.dispatchSignal(@intCast(num));
            writeAllFd(client_fd, "ok\n");
        } else |_| {
            writeAllFd(client_fd, "error: invalid signal number\n");
        }
    } else if (mem.eql(u8, cmd, "list-bars")) {
        var resp: ArrayList(u8) = .empty;
        defer resp.deinit(app.allocator);
        resp.appendSlice(app.allocator, "[\n") catch return;
        for (app.active_bars.items, 0..) |b, idx| {
            var b_buf: [256]u8 = undefined;
            const is_vis = if (b.window) |w| (gtk.gtk_widget_get_visible(w) != 0) else false;
            const b_str = mem.print(&b_buf, "  {{\"name\": \"{s}\", \"output\": \"{s}\", \"position\": \"{s}\", \"visible\": {s}, \"modules\": {d}}}{s}\n", .{
                b.name orelse "default",
                b.output orelse "all",
                @tagName(b.position),
                if (is_vis) "true" else "false",
                b.active_modules.items.len,
                if (idx + 1 < app.active_bars.items.len) "," else "",
            }) catch continue;
            resp.appendSlice(app.allocator, b_str) catch continue;
        }
        resp.appendSlice(app.allocator, "]\n") catch return;
        writeAllFd(client_fd, resp.items);
    } else if (mem.eql(u8, cmd, "quit") or mem.eql(u8, cmd, "exit")) {
        writeAllFd(client_fd, "ok\n");
        if (app.main_loop) |loop| gtk.g_main_loop_quit(loop);
    } else if (mem.eql(u8, cmd, "help")) {
        writeAllFd(client_fd, "Commands: toggle [name], hide, show, reload, reload-config, reload-style, signal <n>, list-bars, quit\n");
    } else {
        writeAllFd(client_fd, "error: unknown command. Run 'help' for available commands\n");
    }
}

fn setupSignals(app: *App) void {
    var pfd: [2]posix.fd_t = undefined;
    if (posix.system.pipe2(&pfd, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) return;

    signal_pipe_read_fd = pfd[0];
    signal_pipe_write_fd = pfd[1];

    var act: posix.Sigaction = mem.zeroes(posix.Sigaction);
    act.handler = .{ .handler = onSignalReceived };

    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.USR1, &act, null);
    posix.sigaction(posix.SIG.USR2, &act, null);

    var sig: u32 = 34;
    while (sig <= 64) : (sig += 1) posix.sigaction(@fromBackingInt(@intCast(sig)), &act, null);

    signal_source_id = gtk.g_unix_fd_add(signal_pipe_read_fd, gtk.G_IO_IN, @ptrCast(&onSignalPipeReadable), app);
}

fn teardownSignals() void {
    if (signal_source_id != 0) {
        _ = gtk.g_source_remove(signal_source_id);
        signal_source_id = 0;
    }
    if (signal_pipe_read_fd >= 0) {
        _ = posix.system.close(signal_pipe_read_fd);
        signal_pipe_read_fd = -1;
    }
    if (signal_pipe_write_fd >= 0) {
        _ = posix.system.close(signal_pipe_write_fd);
        signal_pipe_write_fd = -1;
    }
}

fn processSignals(app: *App) gtk.gboolean {
    if (signal_pipe_read_fd < 0) return 1;

    var sig: u32 = 0;
    var sig_buf: [@sizeOf(u32)]u8 = undefined;
    while (posix.read(signal_pipe_read_fd, &sig_buf)) |bytes_read| {
        if (bytes_read != @sizeOf(u32)) break;
        sig = mem.bytesToValue(u32, &sig_buf);

        if (sig == @backingInt(posix.SIG.INT) or sig == @backingInt(posix.SIG.TERM)) {
            debug.print("Received termination signal: exiting cleanly\n", .{});
            if (app.main_loop) |loop| gtk.g_main_loop_quit(loop);
        } else if (sig == @backingInt(posix.SIG.USR1)) {
            debug.print("Received SIGUSR1: toggling bar visibility\n", .{});
            for (app.active_bars.items) |b| b.toggleVisibility();
        } else if (sig == @backingInt(posix.SIG.USR2)) {
            debug.print("Received SIGUSR2: reloading stylesheet\n", .{});
            @import("bar.zig").loadCss(app.style_path, true);
        } else if (sig >= 34 and sig <= 64) {
            const rt_offset = sig - 34;
            debug.print("Received SIGRTMIN+{d}: dispatching to custom modules\n", .{rt_offset});
            modules.CustomModule.dispatchSignal(@intCast(rt_offset));
        }
    } else |_| {}
    return 1;
}

fn onMonitorsChanged(list: ?*gtk.GListModel, position: c_uint, removed: c_uint, added: c_uint, user_data: ?*anyopaque) callconv(.c) void {
    _ = list;
    _ = position;
    if (removed == 0 and added == 0) return;
    debug.print("Display monitors changed (removed={d}, added={d}): reconciling bars\n", .{ removed, added });
    const app: *App = @ptrCast(@alignCast(user_data orelse return));
    app.spawnBars();
}

fn onConfigDebounceTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const app: *App = @ptrCast(@alignCast(user_data orelse return 0));
    app.reload_timer_id = 0;
    app.reloadConfig();
    return 0;
}

fn onConfigFileChanged(monitor: ?*gtk.GFileMonitor, file: ?*gtk.GFile, other_file: ?*gtk.GFile, event_type: c_int, user_data: gtk.gpointer) callconv(.c) void {
    _ = monitor;
    _ = file;
    _ = other_file;
    // 0: CHANGED, 1: CHANGES_DONE_HINT, 3: CREATED, 7: MOVED, 8: RENAMED
    if (event_type == 0 or event_type == 1 or event_type == 3 or event_type == 7 or event_type == 8) {
        const app: *App = @ptrCast(@alignCast(user_data orelse return));
        if (app.reload_timer_id != 0) {
            _ = gtk.g_source_remove(app.reload_timer_id);
        }
        app.reload_timer_id = gtk.g_timeout_add(150, @ptrCast(&onConfigDebounceTimeout), app);
    }
}

fn onStyleDebounceTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const app: *App = @ptrCast(@alignCast(user_data orelse return 0));
    app.style_reload_timer_id = 0;
    debug.print("Live stylesheet hot reload triggered for: {s}\n", .{app.style_path orelse ""});
    Bar.loadCss(app.style_path, true);
    return 0;
}

fn onStyleFileChanged(monitor: ?*gtk.GFileMonitor, file: ?*gtk.GFile, other_file: ?*gtk.GFile, event_type: c_int, user_data: gtk.gpointer) callconv(.c) void {
    _ = monitor;
    _ = file;
    _ = other_file;
    if (event_type == 0 or event_type == 1 or event_type == 3 or event_type == 7 or event_type == 8) {
        const app: *App = @ptrCast(@alignCast(user_data orelse return));
        if (app.style_reload_timer_id != 0) {
            _ = gtk.g_source_remove(app.style_reload_timer_id);
        }
        app.style_reload_timer_id = gtk.g_timeout_add(150, @ptrCast(&onStyleDebounceTimeout), app);
    }
}

const CliArgs = struct {
    config_path: ?[]const u8 = null,
    style_path: ?[]const u8 = null,
    show_help: bool = false,
    show_version: bool = false,
    list_modules: bool = false,
    validate_config: bool = false,
    dump_default_config: bool = false,
    dump_default_style: bool = false,
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
        } else if (mem.eql(u8, arg, "--list-modules")) {
            result.list_modules = true;
        } else if (mem.eql(u8, arg, "--validate-config")) {
            result.validate_config = true;
        } else if (mem.eql(u8, arg, "--dump-default-config")) {
            result.dump_default_config = true;
        } else if (mem.eql(u8, arg, "--dump-default-style")) {
            result.dump_default_style = true;
        }
    }
    return result;
}

fn printModules() void {
    const list =
        \\Available Vergebar modules:
        \\  - clock
        \\  - cpu
        \\  - memory
        \\  - battery
        \\  - network
        \\  - disk
        \\  - temperature
        \\  - backlight
        \\  - backlight/slider
        \\  - pulseaudio/slider
        \\  - load
        \\  - wireplumber
        \\  - bluetooth
        \\  - gpu
        \\  - updates
        \\  - fan
        \\  - ping
        \\  - workspaces
        \\  - window
        \\  - wlr/taskbar
        \\  - tray
        \\  - cava
        \\  - mpris
        \\  - idle_inhibitor
        \\  - power-profiles-daemon
        \\  - upower
        \\  - user
        \\  - gamemode
        \\  - systemd-failed-units
        \\  - mpd
        \\  - jack
        \\  - weather
        \\  - dnd (or notifications)
        \\  - clipboard
        \\  - hyprland/workspaces, hyprland/window, hyprland/submap, hyprland/language
        \\  - sway/workspaces, sway/window, sway/mode, sway/scratchpad, sway/language
        \\  - river/tags, river/layout, river/window, river/mode
        \\  - dwl/tags, dwl/window
        \\  - wayfire/workspaces, wayfire/window
        \\  - mango/workspaces
        \\  - custom/* (or custom)
    ;
    debug.print("{s}\n", .{list});
}

fn printHelp() void {
    const help_text =
        \\vergebar - High-performance Wayland status bar in Zig with GTK4
        \\
        \\Usage:
        \\  vergebar [options]
        \\  vergebar msg <command> [args...]
        \\
        \\Options:
        \\  -c, --config <path>        Path to configuration file (JSON/JSONC)
        \\  -s, --style <path>         Path to CSS stylesheet
        \\  -v, --version              Show version information
        \\  -h, --help                 Show this help message
        \\  --list-modules             List all built-in modules
        \\  --validate-config          Validate configuration and stylesheet syntax without running GUI
        \\  --dump-default-config      Print built-in default configuration JSONC to stdout
        \\  --dump-default-style       Print built-in default stylesheet CSS to stdout
        \\
        \\Commands for 'vergebar msg':
        \\  toggle [bar-name]          Toggle visibility of status bar(s)
        \\  hide                       Hide all status bars
        \\  show                       Show all status bars
        \\  reload                     Reload configuration and CSS stylesheet
        \\  reload-config              Reload configuration file only
        \\  reload-style               Reload CSS stylesheet only
        \\  signal <num>               Dispatch real-time signal offset to custom modules
        \\  list-bars                  Print running bars and metadata as JSON
        \\  quit                       Cleanly exit vergebar
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

pub fn main(init: process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_it: process.Args.Iterator = .init(init.minimal.args);
    _ = args_it.next();
    if (args_it.next()) |first_arg| {
        if (mem.eql(u8, first_arg, "msg")) {
            var cmd_list: ArrayList(u8) = .empty;
            defer cmd_list.deinit(allocator);

            while (args_it.next()) |sub_arg| {
                if (cmd_list.items.len > 0) try cmd_list.append(allocator, ' ');
                try cmd_list.appendSlice(allocator, sub_arg);
            }

            if (cmd_list.items.len == 0) {
                try cmd_list.appendSlice(allocator, "help");
            }

            const resp = utils.ipc.sendClientCommand(allocator, cmd_list.items) catch |err| {
                debug.print("Error: Could not connect to vergebar IPC socket ({})\nIs vergebar running?\n", .{err});
                process.exit(1);
            };
            defer allocator.free(resp);

            _ = posix.system.write(1, @ptrCast(resp.ptr), resp.len);
            if (mem.startsWith(u8, resp, "error:")) {
                process.exit(1);
            }
            return;
        }
    }

    const cli = parseArgs(init.minimal.args);
    if (cli.show_help) {
        printHelp();
        return;
    }

    if (cli.show_version) {
        debug.print("vergebar v{s}\n", .{VERSION});
        return;
    }

    if (cli.dump_default_config) {
        _ = posix.system.write(1, @ptrCast(config_pkg.DEFAULT_CONFIG.ptr), config_pkg.DEFAULT_CONFIG.len);
        return;
    }

    if (cli.dump_default_style) {
        _ = posix.system.write(1, @ptrCast(config_pkg.DEFAULT_STYLE.ptr), config_pkg.DEFAULT_STYLE.len);
        return;
    }

    if (cli.list_modules) {
        printModules();
        return;
    }

    if (cli.validate_config) {
        const config_path = cli.config_path orelse config_pkg.findDefaultConfigPath(io, allocator);
        defer if (cli.config_path == null and config_path != null) allocator.free(config_path.?);

        if (config_path == null) {
            debug.print("Error: No configuration file found to validate.\n", .{});
            process.exit(1);
        }

        const cp = config_path.?;
        debug.print("Validating configuration: {s} ...\n", .{cp});
        const loaded = config_pkg.loadConfigsFromFile(io, allocator, cp) catch |err| {
            debug.print("Configuration validation failed: error loading '{s}': {}\n", .{ cp, err });
            process.exit(1);
        };
        defer {
            for (loaded) |*bc| {
                var bc_mut = bc.*;
                bc_mut.deinit();
            }
            allocator.free(loaded);
        }

        debug.print("Configuration is valid! ({d} bar definition(s) parsed successfully)\n", .{loaded.len});

        var style_path = cli.style_path;
        var allocated_style: ?[]const u8 = null;
        if (style_path == null) {
            if (config_pkg.findVergebarStylePath(io, allocator)) |vp| {
                style_path = vp;
                allocated_style = vp;
            } else if (config_pkg.findDefaultStylePath(io, allocator)) |sp| {
                style_path = sp;
                allocated_style = sp;
            }
        }
        defer if (allocated_style) |p| allocator.free(p);

        if (style_path) |sp| {
            debug.print("Checking stylesheet: {s} ...\n", .{sp});
            const sysfs = @import("utils").sysfs;
            if (sysfs.fileExists(io, sp)) {
                debug.print("Stylesheet found and readable.\n", .{});
            } else {
                debug.print("Warning: Stylesheet file could not be read or does not exist.\n", .{});
            }
        }

        debug.print("All checks passed.\n", .{});
        return;
    }

    if (env.get("GSK_RENDERER") == null) _ = gtk.g_setenv("GSK_RENDERER", "cairo", 0);
    if (env.get("MESA_LOG_LEVEL") == null) _ = gtk.g_setenv("MESA_LOG_LEVEL", "error", 0);

    gtk.gtk_init();

    const config_path = cli.config_path orelse config_pkg.findDefaultConfigPath(io, allocator);
    defer if (cli.config_path == null and config_path != null) allocator.free(config_path.?);

    var configs_list: []BarConfig = &.{};
    var has_loaded_cfg = false;

    if (config_path) |cp| {
        debug.print("Loading config from: {s}\n", .{cp});
        if (config_pkg.loadConfigsFromFile(io, allocator, cp)) |loaded| {
            configs_list = loaded;
            has_loaded_cfg = true;
        } else |err| {
            debug.print("Failed to load config {s}: {}, falling back to defaults\n", .{ cp, err });
        }
    }

    if (!has_loaded_cfg or configs_list.len == 0) {
        debug.print("Using built-in default bar configuration\n", .{});
        if (config_pkg.loadConfigsFromString(io, allocator, config_pkg.DEFAULT_CONFIG)) |loaded| {
            configs_list = loaded;
        } else |_| {
            var arena: heap.ArenaAllocator = .init(allocator);
            const a = arena.allocator();
            const def_cfg: BarConfig = .{
                .arena = arena,
                .modules_map = .init(a),
                .modules_left = try a.dupe([]const u8, &.{ "workspaces", "window" }),
                .modules_center = try a.dupe([]const u8, &.{"clock"}),
                .modules_right = try a.dupe([]const u8, &.{ "cpu", "memory", "network", "wireplumber", "tray" }),
            };

            const single = try allocator.alloc(BarConfig, 1);
            single[0] = def_cfg;
            configs_list = single;
        }
    }

    var style_path: ?[]const u8 = cli.style_path;
    var allocated_style_path: ?[]const u8 = null;
    if (style_path == null) {
        if (config_pkg.findVergebarStylePath(io, allocator)) |vp| {
            style_path = vp;
            allocated_style_path = vp;
        } else if (has_loaded_cfg) {
            if (config_pkg.findDefaultStylePath(io, allocator)) |sp| {
                style_path = sp;
                allocated_style_path = sp;
            }
        }
    }

    defer if (allocated_style_path) |p| allocator.free(p);

    if (style_path) |sp| {
        debug.print("Loading style from: {s}\n", .{sp});
    } else {
        debug.print("Using built-in default style\n", .{});
    }

    var app: App = .{
        .io = io,
        .allocator = allocator,
        .configs_list = configs_list,
        .active_bars = .empty,
        .style_path = style_path,
        .config_path = config_path,
    };
    defer app.deinit();

    setupSignals(&app);
    defer teardownSignals();

    var sock_buf: [256]u8 = undefined;
    if (utils.ipc.getVergebarSocketPath(&sock_buf)) |sp| {
        if (utils.ipc.createIpcServer(sp)) |fd| {
            app.ipc_server_fd = fd;
            app.ipc_socket_path = allocator.dupe(u8, sp) catch null;
            app.ipc_source_id = gtk.g_unix_fd_add(fd, gtk.G_IO_IN, @ptrCast(&onIpcSocketAccept), &app);
            debug.print("IPC server listening on: {s}\n", .{sp});
        } else |err| {
            debug.print("Warning: Failed to start IPC server: {}\n", .{err});
        }
    } else |_| {}

    app.spawnBars();

    const display = gtk.gdk_display_get_default();
    const monitor_list = if (display) |d| gtk.gdk_display_get_monitors(d) else null;
    if (monitor_list) |ml| {
        _ = gtk.g_signal_connect_data(ml, "items-changed", @ptrCast(&onMonitorsChanged), &app, null, 0);
    }

    if (config_path) |cp| {
        var path_z: [fs.max_path_bytes]u8 = undefined;
        const len = @min(cp.len, path_z.len - 1);
        @memcpy(path_z[0..len], cp[0..len]);
        path_z[len] = 0;

        const gfile = gtk.g_file_new_for_path(@ptrCast(&path_z));
        if (gfile) |gf| {
            defer gtk.g_object_unref(gf);
            app.config_file_monitor = gtk.g_file_monitor_file(gf, 0, null, null);
            if (app.config_file_monitor) |mon| {
                _ = gtk.g_signal_connect_data(mon, "changed", @ptrCast(&onConfigFileChanged), &app, null, 0);
                debug.print("Live config hot reload enabled for: {s}\n", .{path_z[0..len]});
            }
        }
    }

    if (style_path) |sp| {
        var path_z: [fs.max_path_bytes]u8 = undefined;
        const len = @min(sp.len, path_z.len - 1);
        @memcpy(path_z[0..len], sp[0..len]);
        path_z[len] = 0;

        const gfile = gtk.g_file_new_for_path(@ptrCast(&path_z));
        if (gfile) |gf| {
            defer gtk.g_object_unref(gf);
            app.style_file_monitor = gtk.g_file_monitor_file(gf, 0, null, null);
            if (app.style_file_monitor) |mon| {
                _ = gtk.g_signal_connect_data(mon, "changed", @ptrCast(&onStyleFileChanged), &app, null, 0);
                debug.print("Live stylesheet hot reload enabled for: {s}\n", .{path_z[0..len]});
            }
        }
    }

    const loop = gtk.g_main_loop_new(null, 0);
    app.main_loop = loop;
    defer {
        app.main_loop = null;
        if (loop) |l| gtk.g_object_unref(l);
    }
    gtk.g_main_loop_run(loop);
}
