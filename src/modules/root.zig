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

pub const BaseModule = @import("base/root.zig");
pub const ClockModule = @import("clock/root.zig");
pub const CpuModule = @import("cpu/root.zig");
pub const MemoryModule = @import("memory/root.zig");
pub const DiskModule = @import("disk/root.zig");
pub const NetworkModule = @import("network/root.zig");
pub const BatteryModule = @import("battery/root.zig");
pub const BacklightModule = @import("backlight/root.zig");
pub const TemperatureModule = @import("temperature/root.zig");
pub const CustomModule = @import("custom/root.zig");
pub const WorkspacesModule = @import("workspaces/root.zig");
pub const TrayModule = @import("tray/root.zig");
pub const WindowModule = @import("window/root.zig");
pub const WireplumberModule = @import("wireplumber/root.zig");
pub const MprisModule = @import("mpris/root.zig");
pub const BluetoothModule = @import("bluetooth/root.zig");

pub const SliderModule = @import("sliders/root.zig");
pub const IdleInhibitorModule = @import("idle_inhibitor/root.zig");
pub const PowerProfilesModule = @import("power_profiles/root.zig");
pub const UPowerModule = @import("upower/root.zig");
pub const LoadModule = @import("load/root.zig");
pub const UserModule = @import("user/root.zig");
pub const ImageModule = @import("image/root.zig");
pub const GamemodeModule = @import("gamemode/root.zig");
pub const SystemdFailedModule = @import("systemd_failed/root.zig");
pub const KeyboardStateModule = @import("keyboard_state/root.zig");
pub const PrivacyModule = @import("privacy/root.zig");
pub const GpuModule = @import("gpu/root.zig");
pub const UpdatesModule = @import("updates/root.zig");
pub const FanModule = @import("fan/root.zig");
pub const PingModule = @import("ping/root.zig");
pub const CompositorModeModule = @import("compositor_modes/root.zig");
pub const TaskbarModule = @import("taskbar/root.zig");
pub const GroupModule = @import("group/root.zig");
pub const MpdModule = @import("mpd/root.zig");
pub const JackModule = @import("jack/root.zig");
pub const CavaModule = @import("cava/root.zig");
pub const WeatherModule = @import("weather/root.zig");
pub const DndModule = @import("dnd/root.zig");
pub const ClipboardModule = @import("clipboard/root.zig");
pub const PowerModule = @import("power/root.zig");

pub const ModuleHandle = struct {
    widget: ?*gtk.GtkWidget,
    ptr: *anyopaque,
    deinit_fn: *const fn (ptr: *anyopaque) void,

    pub fn deinit(this: ModuleHandle) void {
        this.deinit_fn(this.ptr);
    }
};

pub fn makeHandle(comptime T: type, mod: *T) ModuleHandle {
    const widget: ?*gtk.GtkWidget = if (@hasField(T, "base"))
        mod.base.button
    else if (@hasField(T, "box"))
        mod.box
    else if (@hasField(T, "scale"))
        mod.scale
    else
        null;

    return .{
        .widget = widget,
        .ptr = mod,
        .deinit_fn = struct {
            fn deinit(ptr: *anyopaque) void {
                const m: *T = @ptrCast(@alignCast(ptr));
                m.deinit();
            }
        }.deinit,
    };
}

inline fn initMod(comptime Mod: type, io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) ?ModuleHandle {
    const mod = Mod.create(io, allocator, name, settings) catch return null;
    return makeHandle(Mod, mod);
}

pub fn createModule(io: Io, allocator: Allocator, name: []const u8, config: *BarConfig) ?ModuleHandle {
    const settings = config.getModuleSettings(name);

    if (mem.startsWith(u8, name, "group/") or mem.startsWith(u8, name, "group#") or mem.eql(u8, name, "group")) {
        const mod = GroupModule.create(io, allocator, name, config) catch return null;
        return makeHandle(GroupModule, mod);
    } else if (mem.eql(u8, name, "clock")) {
        return initMod(ClockModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "cpu")) {
        return initMod(CpuModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "memory")) {
        return initMod(MemoryModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "disk")) {
        return initMod(DiskModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "network")) {
        return initMod(NetworkModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "battery")) {
        return initMod(BatteryModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "backlight")) {
        return initMod(BacklightModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "backlight/slider")) {
        const mod = SliderModule.create(io, allocator, name, settings, .backlight) catch return null;
        return makeHandle(SliderModule, mod);
    } else if (mem.eql(u8, name, "pulseaudio/slider")) {
        const mod = SliderModule.create(io, allocator, name, settings, .pulseaudio) catch return null;
        return makeHandle(SliderModule, mod);
    } else if (mem.eql(u8, name, "temperature")) {
        return initMod(TemperatureModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "workspaces") or
        mem.startsWith(u8, name, "workspaces") or
        mem.eql(u8, name, "hyprland/workspaces") or
        mem.eql(u8, name, "sway/workspaces") or
        mem.eql(u8, name, "niri/workspaces") or
        mem.eql(u8, name, "kde/workspaces"))
    {
        return initMod(WorkspacesModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "tray")) {
        return initMod(TrayModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "window") or
        mem.startsWith(u8, name, "window") or
        mem.eql(u8, name, "hyprland/window") or
        mem.eql(u8, name, "sway/window") or
        mem.eql(u8, name, "niri/window"))
    {
        return initMod(WindowModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "wlr/taskbar")) {
        return initMod(TaskbarModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "wireplumber") or
        mem.startsWith(u8, name, "wireplumber#") or
        mem.startsWith(u8, name, "wireplumber/") or
        mem.eql(u8, name, "pulseaudio") or
        mem.startsWith(u8, name, "pulseaudio#") or
        mem.startsWith(u8, name, "pulseaudio/"))
    {
        return initMod(WireplumberModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "mpris")) {
        return initMod(MprisModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "bluetooth")) {
        return initMod(BluetoothModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "idle_inhibitor")) {
        return initMod(IdleInhibitorModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "power-profiles-daemon")) {
        return initMod(PowerProfilesModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "upower")) {
        return initMod(UPowerModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "load")) {
        return initMod(LoadModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "user")) {
        return initMod(UserModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "image")) {
        return initMod(ImageModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "gamemode")) {
        return initMod(GamemodeModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "systemd-failed-units")) {
        return initMod(SystemdFailedModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "keyboard-state")) {
        return initMod(KeyboardStateModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "privacy")) {
        return initMod(PrivacyModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "cava")) {
        return initMod(CavaModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "gpu")) {
        return initMod(GpuModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "updates")) {
        return initMod(UpdatesModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "fan")) {
        return initMod(FanModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "ping")) {
        return initMod(PingModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "power") or mem.eql(u8, name, "session")) {
        return initMod(PowerModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "mpd")) {
        return initMod(MpdModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "jack")) {
        return initMod(JackModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "weather") or mem.startsWith(u8, name, "weather#")) {
        return initMod(WeatherModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "dnd") or mem.startsWith(u8, name, "dnd#") or mem.eql(u8, name, "notifications") or mem.startsWith(u8, name, "notifications#")) {
        return initMod(DndModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "clipboard") or mem.startsWith(u8, name, "clipboard#")) {
        return initMod(ClipboardModule, io, allocator, name, settings);
    } else if (mem.eql(u8, name, "hyprland/submap")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .hyprland_submap) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "hyprland/language")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .hyprland_language) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "hyprland/windowcount")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .hyprland_windowcount) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "sway/mode")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .sway_mode) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "sway/scratchpad")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .sway_scratchpad) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "sway/language")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .sway_language) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "river/mode")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .river_mode) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "river/layout")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .river_layout) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "river/window")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .river_window) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "dwl/window")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .dwl_window) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "wayfire/window")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .wayfire_window) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "mango/keymode")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .mango_keymode) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else if (mem.eql(u8, name, "mango/language")) {
        const mod = CompositorModeModule.create(io, allocator, name, settings, .mango_language) catch return null;
        return makeHandle(CompositorModeModule, mod);
    } else {
        return initMod(CustomModule, io, allocator, name, settings);
    }
}
