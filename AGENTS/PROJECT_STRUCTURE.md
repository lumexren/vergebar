# Project Structure

This document provides a detailed map of the `vergebar` directory layout, files, and architectural roles.

---

## 🌳 Directory Map

```
vergebar/
├── AGENTS/                     # AI Agent knowledge base & developer guides
│   ├── README.md               # Main entrypoint & table of contents
│   ├── ARCHITECTURE.md         # Bar architecture, layer-shell & GTK4 pipeline
│   ├── PROJECT_STRUCTURE.md    # Codebase directory layout & role reference
│   ├── BUILD_AND_TEST.md       # Toolchain, build steps, dependencies & testing
│   ├── CONVENTIONS.md          # Coding style, parameter ordering & memory rules
│   ├── SUBSYSTEMS.md           # Deep dives into Bar, Config, BaseModule, Sysinfo
│   └── CREATING_MODULES.md     # How to implement a new Vergebar module
│
├── examples/                   # Sample configuration & styling
│   ├── config.jsonc            # Example Waybar-compatible JSONC configuration
│   └── style.css               # Example CSS stylesheet
│
├── src/                        # Core source code
│   ├── root.zig                # Process entrypoint, signal self-pipe, CLI parser
│   │
│   ├── bar.zig                 # Wayland Status Bar harness (GTK4 window, layer-shell, layout, CSS)
│   │
│   ├── bindings/               # C ABI and system bindings
│   │   ├── root.zig            # Module root exporting nvml, amdsmi, statvfs, pipewire
│   │   ├── gtk.zig             # GTK4, GDK4, GLib/GIO, gtk4-layer-shell C bindings
│   │   ├── gdbus.zig           # GDBus client and method invocation helpers
│   │   ├── amdsmi.zig          # AMD SMI (ROCm) C header bindings
│   │   ├── nvml.zig            # NVIDIA NVML (CUDA) C header bindings
│   │   ├── statvfs.zig         # POSIX statvfs C wrapper for filesystem sizing
│   │   └── pipewire/           # PipeWire client bindings and C wrapper
│   │       ├── root.zig
│   │       └── wrapper.c
│   │
│   ├── modules/                # Status bar module implementations
│   │   ├── root.zig            # ModuleHandle factory (`createModule`)
│   │   ├── backlight/root.zig  # Display brightness monitor (D-Bus logind + brightnessctl)
│   │   ├── base/               # BaseModule GTK wrapper
│   │   │   ├── root.zig        # BaseModule struct & methods
│   │   │   ├── StateThreshold.zig
│   │   │   └── MenuItemActionContext.zig
│   │   ├── battery/root.zig    # Battery percentage, charging state (sysfs/UPower)
│   │   ├── bluetooth/root.zig  # Bluetooth status, paired devices & connect popover
│   │   ├── cava/root.zig       # CAVA audio visualizer
│   │   ├── clipboard/root.zig  # Wayland clipboard monitor via event-driven GDK
│   │   ├── clock/root.zig      # Date and time display with calendar popover
│   │   ├── compositor_modes/   # Submap / mode indicators (event-driven socket)
│   │   │   ├── root.zig
│   │   │   └── CompositorModeType.zig
│   │   ├── cpu/root.zig        # CPU percentage monitor
│   │   ├── custom/             # Custom user scripts (streaming or periodic)
│   │   │   ├── root.zig
│   │   │   └── SignalModuleNode.zig
│   │   ├── disk/root.zig       # Filesystem usage & mount stats
│   │   ├── dnd/root.zig        # Do Not Disturb & notification status toggle (D-Bus)
│   │   ├── fan/root.zig        # Fan speed monitor
│   │   ├── gamemode/root.zig   # Feral GameMode active status
│   │   ├── gpu/root.zig        # GPU usage, memory & thermal monitoring (NVIDIA/AMD/Intel)
│   │   ├── group/root.zig      # Nested / collapsible module groups (drawer mode via GtkRevealer)
│   │   ├── idle_inhibitor/root.zig # Wayland idle inhibitor toggle
│   │   ├── image/root.zig      # Static / dynamic GTK image widget
│   │   ├── jack/root.zig       # JACK audio server status
│   │   ├── keyboard_state/root.zig # Active keyboard layout indicator (TR, EN, US) & click-cycle
│   │   ├── load/root.zig       # System load averages
│   │   ├── memory/root.zig     # RAM and swap usage monitor
│   │   ├── mpd/                # Music Player Daemon client
│   │   │   ├── root.zig
│   │   │   └── MpdData.zig
│   │   ├── mpris/root.zig      # Media player controls, metadata & mini-player popover
│   │   ├── network/root.zig    # Ethernet / Wi-Fi metrics, IP, bandwidth
│   │   ├── power_profiles/root.zig # power-profiles-daemon switcher
│   │   ├── privacy/root.zig    # Microphone / camera active privacy indicators
│   │   ├── sliders/            # Interactive slider widgets (volume, brightness)
│   │   │   ├── root.zig
│   │   │   └── SliderType.zig
│   │   ├── systemd_failed/root.zig # Systemd failed units monitor
│   │   ├── taskbar/            # Foreign toplevel taskbar (event-driven compositor socket)
│   │   │   ├── root.zig
│   │   │   └── TaskItem.zig
│   │   ├── temperature/root.zig # Hardware thermal sensor monitor
│   │   ├── tray/               # System tray via StatusNotifierItem (SNI) D-Bus
│   │   │   ├── root.zig
│   │   │   ├── TrayItem.zig
│   │   │   ├── MenuItemClickContext.zig
│   │   │   └── WatcherItemWatch.zig
│   │   ├── updates/root.zig    # Package manager updates monitor
│   │   ├── upower/root.zig     # UPower battery devices
│   │   ├── user/root.zig       # Current user and uptime
│   │   ├── weather/root.zig    # Live weather forecast (native std.http.Client)
│   │   ├── window/root.zig     # Active window title display (event-driven socket)
│   │   ├── wireplumber/root.zig # Audio volume, mute, device route & sink switcher popover
│   │   └── workspaces/         # Wayland workspaces (Hyprland, Sway, Niri, River, etc.)
│   │       ├── root.zig
│   │       ├── Compositor.zig
│   │       └── WorkspaceButton.zig
│   │
│   ├── sysinfo/                # System metric readers and domain logic
│   │   ├── root.zig            # Root aggregator of sysinfo collectors
│   │   ├── backlight/          # Reads `/sys/class/backlight`
│   │   ├── battery/            # Reads sysfs battery data or UPower
│   │   ├── bluetooth/          # Interacts with BlueZ via GDBus
│   │   ├── cpu/                # Parses `/proc/stat` & `/sys/devices/system/cpu`
│   │   ├── disk/               # Parses `/proc/mounts` and queries `statvfs`
│   │   ├── fan/                # Reads `/sys/class/hwmon` fan inputs
│   │   ├── gpu/                # Abstraction layer for NVML, AMD SMI, DRM
│   │   ├── load/               # Reads `/proc/loadavg` for system load averages
│   │   ├── memory/             # Parses `/proc/meminfo`
│   │   ├── mpris/              # Interacts with org.mpris.MediaPlayer2
│   │   ├── network/            # Parses `/proc/net/dev`, `/proc/net/route`, DNS
│   │   ├── pipewire/           # Connects to PipeWire / PulseAudio interfaces
│   │   ├── temperature/        # Reads `/sys/class/thermal` and `/sys/class/hwmon`
│   │   ├── updates/            # Queries package managers (pacman, apt, etc.)
│   │   └── common/             # Sysfs integer, milli, and string helpers
│   │
│   └── utils/                  # Shared utilities
│       ├── root.zig            # Exports sh, sysfs, env, Replacer, Json, Process, etc.
│       ├── config/             # Waybar JSON/JSONC Configuration System
│       │   ├── root.zig        # Config finder and exports
│       │   ├── bar_config.zig  # BarConfig parser, per-output matching, settings
│       │   ├── jsonc.zig       # JSONC parser stripping comments and trailing commas
│       │   ├── loader.zig      # Config loader wrapper
│       │   └── default/        # Built-in fallback config.jsonc and style.css
│       ├── sh.zig              # Shell execution and process streaming (stateless)
│       ├── sysfs.zig           # Sysfs/procfs readers and file checks (stateless)
│       ├── env.zig             # Environment variables and path resolution (stateless)
│       ├── ipc.zig             # UNIX domain socket server, client & compositor sockets (Hyprland, Sway, Niri)
│       ├── replacer/           # Dynamic placeholder engine (`{icon}`, `{usage}`)
│       ├── json/               # Streaming JSON encoder
│       ├── process/            # Process iterator, helpers, exec
│       └── watcher/            # Signal watcher primitives
│
├── build.zig                   # Zig build script (GTK4 & layer-shell pkg-config)
├── build.zig.zon               # Package metadata & dependencies
├── LICENSE                     # GNU General Public License v3.0
└── README.md                   # Project overview & quick start
```
