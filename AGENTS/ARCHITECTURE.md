# Architecture & Design

This document details the architectural design and runtime mechanics of **`vergebar`**.

---

## 1. High-Level Concept

`vergebar` is a native Wayland status bar written in Zig. It combines the modern GTK4 toolkit and `gtk4-layer-shell` with the ultra-fast sysinfo engines and template systems originating from `zig-waybar-contrib`.

Unlike traditional setups that execute external helper scripts, `vergebar` runs as a single, lightweight binary (~8–15 MB RSS) that:
- Natively connects to Wayland compositors using the `wlr-layer-shell` protocol via `gtk4-layer-shell`.
- Parses Waybar-standard JSONC configurations and CSS stylesheets directly.
- Embeds status modules as native GTK4 widgets inside a 3-part layout (`modules-left`, `modules-center`, `modules-right`).
- Updates modules efficiently through GLib timers, event subscriptions (D-Bus), and POSIX signals.

---

## 2. End-to-End System Architecture

```
┌────────────────────────────────────────────────────────┐
│                   CLI / Environment                    │
│           (Args: -c config.jsonc, -s style.css)        │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│               Configuration Parser (JSONC)             │
│        (Extracts BarConfig structs, per-monitor)       │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│            Bar Manager (`src/bar.zig`)                 │
│   • Spawns GTK Window with gtk4-layer-shell            │
│   • Configures anchors, exclusive zones, margins       │
│   • Sets up GtkCenterBox (left, center, right)         │
│   • Loads and hot-reloads CSS stylesheets              │
└────────────┬─────────────────────────────┬─────────────┘
             │                             │
             ▼                             ▼
┌───────────────────────────┐ ┌──────────────────────────┐
│      Module Harness       │ │   Signal / Event Loop    │
│  (`src/modules/root.zig`) │ │   (GTK Main Loop, Pipe)  │
│                           │ │                          │
│ • Factory: `createModule` │ │ • GLib Timers            │
│ • BaseModule GTK widgets  │ │ • Self-Pipe (SIGUSR1/2)  │
│ • Click actions / menus   │ │ • GDBus events           │
└────────────┬──────────────┘ └────────────┬─────────────┘
             │                             │
             ▼                             ▼
┌────────────────────────────────────────────────────────┐
│         Hardware & OS Metric Collectors (`sysinfo`)    │
│  (/proc, /sys, GDBus, NVML, AMD-SMI, statvfs)         │
└────────────────────────────────────────────────────────┘
```

---

## 3. Runtime Lifecycle & The Event Loop

### 3.1. Process Initialization (`src/root.zig`)
1. **GTK Initialization:** Calls `gtk.gtk_init()` and sets default renderers (`GSK_RENDERER=cairo` fallback).
2. **Signal Handler Setup:** Creates a non-blocking POSIX self-pipe and installs signal handlers for `SIGUSR1`, `SIGUSR2`, and real-time signals `34..64`. Wakes up the GLib event loop via `g_unix_fd_add` without polling timers.
3. **Configuration Discovery:** Finds `config.jsonc` (in `~/.config/vergebar/` or `~/.config/waybar/`) and parses into `[]BarConfig` using `io: Io` explicitly. Also sets up live configuration hot-reloading via `GFileMonitor`.
4. **CSS Discovery:** Discovers and applies `style.css` with automatic live reload on file modification.
5. **Bar Instantiation & Hotplugging:** Inspects connected `GdkMonitor` outputs and creates a `Bar` instance for each configured monitor via:
   ```zig
   const bar = try Bar.create(io, allocator, cfg, monitor, style_path);
   ```
   Monitors are observed via `GListModel` `"items-changed"` signals so bars dynamically spawn and reconcile upon monitor plug/unplug events.
6. **Main Loop:** Enters `gtk.g_main_loop_run()`.

### 3.2. Bar Creation & Layer Shell (`src/bar.zig`)
For each bar:
- Initializes `gtk_layer_init_for_window()`.
- Sets layer namespace to `"vergebar"`.
- Anchors the window according to `position` (`top`, `bottom`, `left`, `right`).
- Sets `gtk_layer_auto_exclusive_zone_enable()` so the compositor reserves screen space.
- Populates `modules_left`, `modules_center`, and `modules_right` using `modules.createModule(io, allocator, name, config)`.

---

## 4. Module Architecture & `BaseModule`

Every status bar module wraps `BaseModule` (`src/modules/base/root.zig`):
- **Widget Hierarchy:** A `GtkButton` containing a `GtkLabel` (or custom layout like `GtkBox` for groups / workspaces).
- **CSS Classes:** Adds base class names (e.g., `cpu`, `memory`, `warning`, `critical`).
- **Click Actions:** Dispatches shell commands or actions on click:
  - `on-click` (Left click)
  - `on-click-middle` (Middle click)
  - `on-click-right` (Right click)
  - `on-scroll-up` / `on-scroll-down`
- **Context Menus:** Supports custom menu actions triggered by click actions.

### Module Factory Function
Module creation follows this canonical signature:
```zig
pub fn createModule(
    io: std.Io,
    allocator: Allocator,
    name: []const u8,
    config: *BarConfig,
) ?ModuleHandle
```
Modules requiring I/O follow the exact same ordering:
```zig
pub fn create(
    io: std.Io,
    allocator: Allocator,
    name: []const u8,
    settings: ModuleSettings,
) !*MyModule
```

---

## 5. Signal Handling Pipeline

To prevent signal handler deadlocks with GTK/GLib APIs, `vergebar` uses the POSIX self-pipe pattern:
1. `onSignalReceived(sig: posix.SIG)` writes the signal integer to `signal_pipe_write_fd`.
2. `processSignals` runs on the GTK main loop thread, safely reading all queued signals:
   - **`SIGUSR1`**: Toggles bar visibility (`bar.toggleVisibility()`).
   - **`SIGUSR2`**: Reloads CSS stylesheets (`bar.loadCss(path, true)`).
   - **`SIGRTMIN+n`**: Dispatches real-time signal offset `n` to matching custom modules (`modules.custom.dispatchSignal(rt_offset)`).
