# Subsystems Deep Dive

This document provides a technical deep dive into the core reusable subsystems of **`vergebar`**.

---

## 1. Configuration & JSONC Engine (`src/utils/config/`)

The configuration subsystem provides drop-in compatibility with standard Waybar configuration files.

### 1.1. Path Resolution
1. Checks command-line `-c <path>`.
2. Falls back to user config directories in order:
   - `~/.config/vergebar/config.jsonc`
   - `~/.config/vergebar/config.json`
   - `~/.config/vlybar/config.jsonc`
   - `~/.config/waybar/config.jsonc`
3. If no file exists, falls back to the built-in default JSONC configuration.

### 1.2. JSONC Comment & Trailing Comma Stripping (`src/utils/config/jsonc.zig`)
Waybar configurations routinely contain C++ single-line comments (`//`), block comments (`/* ... */`), and trailing commas in arrays/objects.
- `cleanJsonc(allocator, input)` converts JSONC into strict JSON before parsing.
- Allocates a clean buffer stripping all comments while preserving string literal contents (e.g. format strings containing `//`).

### 1.3. `BarConfig` & `ModuleSettings` (`src/utils/config/BarConfig.zig`, `ModuleSettings.zig`)
- Parses bar geometries: `layer`, `position`, `keyboard-mode`, `height`, `width`, `margin-top`, etc.
- Multi-bar support: parses arrays of bar configurations matching specific outputs (`"output": "DP-1"` or `"output": ["eDP-1", "HDMI-A-1"]`).
- `loadConfigsFromFile(io: Io, allocator: Allocator, path: []const u8)` and `loadConfigsFromString(io: Io, allocator: Allocator, content: []const u8)` in `src/utils/config/root.zig` explicitly receive `io` without global states.
- Dedicated struct files under `src/utils/config/`: `BarConfig.zig`, `ModuleSettings.zig`, `Layer.zig`, `Position.zig`, `KeyboardMode.zig`, `SharedArena.zig`.
- `ModuleSettings` provides typed extraction for module blocks:
  - `getString(key)`, `getInt(key)`, `getFloat(key)`, `getBool(key)`
  - `getStringOr(key, default)`, `getIntOr(T, key, default)`, `getFloatOr(T, key, default)`, `getBoolOr(key, default)`
  - Generic strongly-typed getter: `getOr(comptime T, key, default_val)`

---

## 2. Bar Harness & Layer-Shell (`src/bar.zig`)

Manages the GTK4 window surface and Wayland layer-shell protocol binding.

### Key Functions
- `create(io: std.Io, allocator: Allocator, config: *BarConfig, monitor: ?*gtk.GdkMonitor, style_path: ?[]const u8) !*Bar`:
  Instantiates the GTK window, applies `gtk4-layer-shell` properties, builds the `GtkCenterBox`, and populates all module widgets.
- `loadCss(path: ?[]const u8, reload: bool)`:
  Compiles CSS and adds `GtkStyleProvider` to `gdk_display_get_default()`.
- `toggleVisibility(this: *Bar)`:
  Hides or reveals the bar window on `SIGUSR1`.

---

## 3. `BaseModule` (`src/modules/base/root.zig`)

The foundation widget for status bar modules.

### Structure
- Holds `io: std.Io` and `allocator: Allocator` explicitly.
- Wraps a `GtkButton` containing an inner `GtkLabel`.
- Applies baseline CSS classes: `.module`, `.<module-name>`, and custom classes.
- Connects GTK `"clicked"` signals to action dispatchers:
  - Executes configured shell commands (`on-click`, `on-click-middle`, `on-click-right`).
  - Supports GTK context menus (`GtkPopoverMenu`) if menu items are defined.

### Methods
- `setText(this: *BaseModule, text: []const u8)`
- `setTooltip(this: *BaseModule, tooltip: []const u8)`
- `addCssClass(this: *BaseModule, class_name: [:0]const u8)`
- `removeCssClass(this: *BaseModule, class_name: [:0]const u8)`

---

## 4. `utils.Replacer` (`src/utils/replacer/root.zig`)

Powers dynamic format strings such as `format = "{icon}  {usage}%"` or `tooltip = "IP: {ipaddr}\nSpeed: {bandwidthDownBytes}"`.

### Features
- Key-value placeholder bindings: `{icon}`, `{usage}`, `{temp}`.
- Precision specifiers: `{frequency:2}` formats float to 2 decimal places.
- Literal escaping: `{{` renders as `{`, `}}` renders as `}`.
- **Pre-tokenized `Template`**: Compile templates once (`Template.compile(allocator, str)`) at module initialization and render with `tmpl.renderBuf(&replacer, &buf)` for allocation-free updates.
- **Zero-Allocation Rendering**: `replacer.renderBuf(template, &buf)` renders directly into a stack buffer without heap allocations.
- **Direct Stream Rendering**: `replacer.renderToWriter(template, &writer)` writes directly to any `std.Io.Writer`.

---

## 5. System Utilities (`src/utils/sh.zig`, `sysfs.zig`, `env.zig`)

Domain-specific modules providing execution, sysfs reading, and environment inspection. **Completely stateless with zero globals**:
- **`utils.sh`**: Shell execution and child process streaming (`runBuf`, `runTrimBuf`, `runAlloc`, `spawnStream`, `sleepSeconds`, `sleepMs`). Every function takes `io: Io` explicitly.
- **`utils.sysfs`**: Kernel attribute inspection (`readLine`, `readNumber`, `fileExists`, `readFileAlloc`, `openDirAbsolute`). Functions take `io: Io` explicitly.
- **`utils.env`**: Stateless environment queries (`get`, `has`, `getHome`, `expandHomeBuf`, `getConfigHome`). Pure Zig compatible with `builtin.link_libc` conditional checks.

---

## 6. System Metric Collectors (`src/sysinfo/`)

Native collectors running directly in-process with minimal syscalls and zero external shell spawns:
- **`CPU` (`src/sysinfo/cpu/`)**: Parses `/proc/stat` and `/sys/devices/system/cpu` to calculate core usages and frequencies.
- **`Load` (`src/sysinfo/load/`)**: Reads `/proc/loadavg` for 1, 5, and 15-minute system load averages.
- **`Memory` (`src/sysinfo/memory/`)**: Reads `/proc/meminfo` for active RAM, free RAM, buffers, caches, and swap.
- **`Network` (`src/sysinfo/network/`)**: Reads `/proc/net/dev` and `/proc/net/route` for bandwidth deltas and default gateway addresses; queries wireless extensions.
- **`Disk` (`src/sysinfo/disk/`)**: Parses `/proc/mounts` and queries `statvfs` for filesystem capacities.
- **`Temperature` (`src/sysinfo/temperature/`)**: Monitors `/sys/class/thermal` and `/sys/class/hwmon`.
- **`Battery` (`src/sysinfo/battery/`)**: D-Bus UPower integration and direct sysfs reading (`readBatterySysfs`, `readAggregateBatteries`). Reads power consumption, health percentage, estimated time-to-full/empty, and charge cycles.
- **`Backlight` (`src/sysinfo/backlight/`)**: D-Bus logind integration and direct sysfs reading (`readBrightness`).

---

## 7. IPC Engine & Compositor Sockets (`src/utils/ipc.zig`)

`vergebar` provides a zero-overhead UNIX domain socket server, client, and direct compositor event sockets:
- **Vergebar IPC Socket:** Resolved via `$XDG_RUNTIME_DIR/vergebar.sock` or `/tmp/vergebar-$UID.sock`. Integrated into GTK main loop via `gtk.g_unix_fd_add`.
- **CLI Commands (`vergebar msg <cmd>`):**
  - `toggle [bar-name]`: Toggles visibility of all bars or target bar.
  - `hide [bar-name]`: Hides bar.
  - `show [bar-name]`: Reveals bar.
  - `reload` / `reload-style`: Reloads CSS styling.
  - `reload-config`: Reloads JSONC configuration and rebuilds bars.
  - `signal <num>`: Triggers custom modules matching signal number.
  - `list-bars`: Lists active bar names, outputs, positions, and visibility.
  - `quit`: Terminates vergebar daemon.
- **Compositor Event Sockets (0ms latency, 0% CPU):**
  - `connectHyprlandEventSocket()`: Connects to Hyprland's `.socket2.sock` event stream in non-blocking mode.
  - `connectSwayEventSocket(payload)`: Connects to Sway/i3 IPC socket with `IPC_SUBSCRIBE` (`["workspace", "window", "mode", "input"]`).
  - `queryHyprlandSocket()`, `querySwaySocket()`, `queryNiriSocket()`: Zero-subprocess direct UNIX domain socket IPC queries.

---

## 8. GDBus Subsystem (`src/bindings/gdbus.zig`)

Zero-subprocess native D-Bus invocation framework:
- Directly calls session and system buses via GLib's `GDBusConnection`.
- Synchronous calls: `callMethodSync`, `getPropertySync`.
- Asynchronous / Fire-and-forget calls: `callMethodFireAndForget`.
- Used across `dnd`, `bluetooth`, `mpris`, `backlight` (systemd-logind), and KWin OSD volume notifications.

---

## 9. Interactive Popovers & Extended Modules

- **WirePlumber Popover (`wireplumber`)**:
  - Right-click opens an interactive `GtkPopover` audio sink device switcher.
  - Setting default sink via `wpctl set-default <id>` and synchronizing WirePlumber device route with KWin OSD.
  - Supports microphone input control when configured with `"source": true` or identifier `wireplumber#source`.
- **Bluetooth Popover (`bluetooth`)**:
  - Right-click opens a paired device management popover.
  - BlueZ D-Bus integration for instant `Connect` / `Disconnect` actions and Bluetooth power toggling.
- **MPRIS Mini Player (`mpris`)**:
  - Right-click opens a mini player popover with album art (`GtkImage`), track metadata, progress bar (`GtkProgressBar`), and playback controls (`Previous`, `PlayPause`, `Next`).
- **Group Drawer Mode (`group`)**:
  - Supports collapsible module drawers via `GtkRevealer`.
  - Configurable transitions (`transition-duration`, `transition-left-to-right`), hover or `click-to-reveal` modes.
- **Keyboard Layout & State (`keyboard_state`)**:
  - Real-time active layout detection (`TR`, `EN`, `US`, etc.) via compositor sockets.
  - Click-to-cycle layout support (`switchxkblayout` / `xkb_switch_layout next`).
  - CapsLock & NumLock hardware LED indicators.
- **`weather` (`src/modules/weather/root.zig`)**: Pure native HTTP/TLS socket fetches via Zig's `std.http.Client` without `curl` or shell subprocesses.
- **`dnd` (`src/modules/dnd/root.zig`)**: Native D-Bus toggle & unread notification counter supporting SwayNC, Dunst, and Mako without shell commands.
- **`clipboard` (`src/modules/clipboard/root.zig`)**: 100% event-driven Wayland clipboard monitoring via GDK clipboard `"changed"` signal without polling or `wl-paste` spawns.

> [!IMPORTANT]
> All sysinfo collectors strictly follow the parameter ordering rule: `(io: Io, allocator: Allocator, ...)`.
