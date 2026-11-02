# Subsystems Deep Dive

This document provides a technical deep dive into the core reusable subsystems of **`vergebar`**.

---

## 1. Configuration & JSONC Engine (`src/config/`)

The configuration subsystem provides drop-in compatibility with standard Waybar configuration files.

### 1.1. Path Resolution
1. Checks command-line `-c <path>`.
2. Falls back to user config directories in order:
   - `~/.config/vergebar/config.jsonc`
   - `~/.config/vergebar/config.json`
   - `~/.config/vlybar/config.jsonc`
   - `~/.config/waybar/config.jsonc`
3. If no file exists, falls back to the built-in default JSONC configuration.

### 1.2. JSONC Comment & Trailing Comma Stripping (`src/config/jsonc.zig`)
Waybar configurations routinely contain C++ single-line comments (`//`), block comments (`/* ... */`), and trailing commas in arrays/objects.
- `stripJsonc(allocator, input)` converts JSONC into strict JSON before parsing.
- Allocates a clean buffer stripping all comments while preserving string literal contents (e.g. format strings containing `//`).

### 1.3. `BarConfig` & `ModuleSettings` (`src/config/bar_config.zig`)
- Parses bar geometries: `layer`, `position`, `height`, `width`, `margin-top`, etc.
- Multi-bar support: parses arrays of bar configurations matching specific outputs (`"output": "DP-1"` or `"output": ["eDP-1", "HDMI-A-1"]`).
- `ModuleSettings` provides typed extraction for module blocks:
  - `getString(key)`, `getInt(key)`, `getFloat(key)`, `getBool(key)`

---

## 2. Bar Harness & Layer-Shell (`src/bar/bar.zig`)

Manages the GTK4 window surface and Wayland layer-shell protocol binding.

### Key Functions
- `create(io: std.Io, allocator: Allocator, config: *BarConfig, monitor: ?*gtk.GdkMonitor, style_path: ?[]const u8) !*Bar`:
  Instantiates the GTK window, applies `gtk4-layer-shell` properties, builds the `GtkCenterBox`, and populates all module widgets.
- `loadCss(path: ?[]const u8, reload: bool)`:
  Compiles CSS and adds `GtkStyleProvider` to `gdk_display_get_default()`.
- `toggleVisibility(self: *Bar)`:
  Hides or reveals the bar window on `SIGUSR1`.

---

## 3. `BaseModule` (`src/modules/base.zig`)

The foundation widget for all status bar modules.

### Structure
- Wraps a `GtkButton` containing an inner `GtkLabel`.
- Applies baseline CSS classes: `.module`, `.<module-name>`, and custom classes.
- Connects GTK `"clicked"` signals to action dispatchers:
  - Executes configured shell commands (`on-click`, `on-click-middle`, `on-click-right`).
  - Supports GTK context menus (`GtkPopoverMenu`) if menu items are defined.

### Methods
- `setText(self: *BaseModule, text: []const u8)`
- `setTooltip(self: *BaseModule, tooltip: []const u8)`
- `addClass(self: *BaseModule, class_name: []const u8)`
- `removeClass(self: *BaseModule, class_name: []const u8)`

---

## 4. `utils.Replacer` (`src/utils/replacer/root.zig`)

Powers dynamic format strings such as `format = "{icon}  {usage}%"` or `tooltip = "IP: {ipaddr}\nSpeed: {bandwidthDownBytes}"`.

### Features
- Key-value placeholder bindings: `{icon}`, `{usage}`, `{temp}`.
- Precision specifiers: `{frequency:2}` formats float to 2 decimal places.
- Literal escaping: `{{` renders as `{`, `}}` renders as `}`.
- Pre-scans buffer sizes to minimize reallocation during widget text generation.

---

## 5. `utils.AppContext` (`src/utils/context.zig`)

A thread-safe singleton holding root execution handles:
- `io`: Active `std.Io` handle.
- `gpa`: Process heap `Allocator`.
- `environ_map`: Environment variable map.
- `getEnv(key)`: Helper to query environment variables without repeating parameter passes.

---

## 6. System Metric Collectors (`src/sysinfo/`)

Inherited from `zig-waybar-contrib`, these native collectors run directly in-process with minimal syscalls and zero external shell spawns:
- **`CPU` (`src/sysinfo/cpu/`)**: Parses `/proc/stat` and `/sys/devices/system/cpu` to calculate core usages and frequencies.
- **`Memory` (`src/sysinfo/memory/`)**: Reads `/proc/meminfo` for active RAM, free RAM, buffers, caches, and swap.
- **`Network` (`src/sysinfo/network/`)**: Reads `/proc/net/dev` and `/proc/net/route` for bandwidth deltas and default gateway addresses; queries wireless extensions.
- **`Disk` (`src/sysinfo/disk/`)**: Parses `/proc/mounts` and queries `statvfs` for filesystem capacities.
- **`Temperature` (`src/sysinfo/temperature/`)**: Monitors `/sys/class/thermal` and `/sys/class/hwmon`.
- **`Battery` / `Backlight`**: Reads `/sys/class/power_supply` and `/sys/class/backlight`.

> [!IMPORTANT]
> All sysinfo collectors strictly follow the parameter ordering rule: `(io: Io, allocator: Allocator, ...)`.
