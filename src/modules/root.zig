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
const Io = std.Io;
const gtk = @import("gtk");
const BarConfig = @import("utils").Config.BarConfig;
const ModuleSettings = @import("utils").Config.ModuleSettings;

pub const base = @import("base.zig");
pub const clock = @import("clock.zig");
pub const cpu = @import("cpu.zig");
pub const memory = @import("memory.zig");
pub const disk = @import("disk.zig");
pub const network = @import("network.zig");
pub const battery = @import("battery.zig");
pub const backlight = @import("backlight.zig");
pub const temperature = @import("temperature.zig");
pub const custom = @import("custom.zig");
pub const workspaces = @import("workspaces.zig");
pub const tray = @import("tray.zig");
pub const window = @import("window.zig");
pub const wireplumber = @import("wireplumber.zig");
pub const mpris = @import("mpris.zig");
pub const bluetooth = @import("bluetooth.zig");

pub const sliders = @import("sliders.zig");
pub const idle_inhibitor = @import("idle_inhibitor.zig");
pub const power_profiles = @import("power_profiles.zig");
pub const upower = @import("upower.zig");
pub const load = @import("load.zig");
pub const user = @import("user.zig");
pub const image = @import("image.zig");
pub const gamemode = @import("gamemode.zig");
pub const systemd_failed = @import("systemd_failed.zig");
pub const keyboard_state = @import("keyboard_state.zig");
pub const privacy = @import("privacy.zig");
pub const compositor_modes = @import("compositor_modes.zig");
pub const taskbar = @import("taskbar.zig");
pub const group = @import("group.zig");
pub const mpd = @import("mpd.zig");
pub const jack = @import("jack.zig");
pub const cava = @import("cava.zig");

pub const ModuleHandle = struct {
    widget: ?*gtk.GtkWidget,
    ptr: *anyopaque,
    deinit_fn: *const fn (ptr: *anyopaque) void,

    pub fn deinit(self: ModuleHandle) void {
        self.deinit_fn(self.ptr);
    }
};

pub fn createModule(
    io: Io,
    allocator: Allocator,
    name: []const u8,
    config: *BarConfig,
) ?ModuleHandle {
    const settings = config.getModuleSettings(name);

    if (mem.startsWith(u8, name, "group/")) {
        const mod = group.GroupModule.create(io, allocator, name, config) catch return null;
        return .{
            .widget = mod.box,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *group.GroupModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "clock")) {
        const mod = clock.ClockModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *clock.ClockModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "cpu")) {
        const mod = cpu.CpuModule.create(io, allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *cpu.CpuModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "memory")) {
        const mod = memory.MemoryModule.create(io, allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *memory.MemoryModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "disk")) {
        const mod = disk.DiskModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *disk.DiskModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "network")) {
        const mod = network.NetworkModule.create(io, allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *network.NetworkModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "battery")) {
        const mod = battery.BatteryModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *battery.BatteryModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "backlight")) {
        const mod = backlight.BacklightModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *backlight.BacklightModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "backlight/slider")) {
        const mod = sliders.SliderModule.create(allocator, name, settings, .backlight) catch return null;
        return .{
            .widget = mod.scale,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *sliders.SliderModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "pulseaudio/slider")) {
        const mod = sliders.SliderModule.create(allocator, name, settings, .pulseaudio) catch return null;
        return .{
            .widget = mod.scale,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *sliders.SliderModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "temperature")) {
        const mod = temperature.TemperatureModule.create(io, allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *temperature.TemperatureModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "workspaces") or
        mem.startsWith(u8, name, "workspaces") or
        mem.eql(u8, name, "hyprland/workspaces") or
        mem.eql(u8, name, "sway/workspaces") or
        mem.eql(u8, name, "niri/workspaces") or
        mem.eql(u8, name, "kde/workspaces"))
    {
        const mod = workspaces.WorkspacesModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.box,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *workspaces.WorkspacesModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "tray")) {
        const mod = tray.TrayModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.box,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *tray.TrayModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "window") or
        mem.startsWith(u8, name, "window") or
        mem.eql(u8, name, "hyprland/window") or
        mem.eql(u8, name, "sway/window") or
        mem.eql(u8, name, "niri/window"))
    {
        const mod = window.WindowModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *window.WindowModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "wlr/taskbar")) {
        const mod = taskbar.TaskbarModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.box,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *taskbar.TaskbarModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "wireplumber") or
        mem.eql(u8, name, "pulseaudio"))
    {
        const mod = wireplumber.WireplumberModule.create(io, allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *wireplumber.WireplumberModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "mpris")) {
        const mod = mpris.MprisModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *mpris.MprisModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "bluetooth")) {
        const mod = bluetooth.BluetoothModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *bluetooth.BluetoothModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "idle_inhibitor")) {
        const mod = idle_inhibitor.IdleInhibitorModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *idle_inhibitor.IdleInhibitorModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "power-profiles-daemon")) {
        const mod = power_profiles.PowerProfilesModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *power_profiles.PowerProfilesModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "upower")) {
        const mod = upower.UPowerModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *upower.UPowerModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "load")) {
        const mod = load.LoadModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *load.LoadModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "user")) {
        const mod = user.UserModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *user.UserModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "image")) {
        const mod = image.ImageModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *image.ImageModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "gamemode")) {
        const mod = gamemode.GamemodeModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *gamemode.GamemodeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "systemd-failed-units")) {
        const mod = systemd_failed.SystemdFailedModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *systemd_failed.SystemdFailedModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "keyboard-state")) {
        const mod = keyboard_state.KeyboardStateModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *keyboard_state.KeyboardStateModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "privacy")) {
        const mod = privacy.PrivacyModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *privacy.PrivacyModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "cava")) {
        const mod = cava.CavaModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *cava.CavaModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "mpd")) {
        const mod = mpd.MpdModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *mpd.MpdModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "jack")) {
        const mod = jack.JackModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *jack.JackModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "hyprland/submap")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .hyprland_submap) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "hyprland/language")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .hyprland_language) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "hyprland/windowcount")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .hyprland_windowcount) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "sway/mode")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .sway_mode) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "sway/scratchpad")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .sway_scratchpad) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "sway/language")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .sway_language) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "river/mode")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .river_mode) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "river/layout")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .river_layout) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "river/window")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .river_window) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "dwl/window")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .dwl_window) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "wayfire/window")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .wayfire_window) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "mango/keymode")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .mango_keymode) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else if (mem.eql(u8, name, "mango/language")) {
        const mod = compositor_modes.CompositorModeModule.create(allocator, name, settings, .mango_language) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *compositor_modes.CompositorModeModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    } else {
        // Fallback to custom module (works for custom/* or anything else!)
        const mod = custom.CustomModule.create(allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *custom.CustomModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
    }
}
