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
│   ├── main.zig                # Process entrypoint, signal self-pipe, CLI parser
│   │
│   ├── bar/                    # Wayland Status Bar harness
│   │   └── bar.zig             # GTK4 window, layer-shell anchors, center-box layout, CSS
│   │
│   ├── bindings/               # C ABI and system bindings
│   │   ├── root.zig            # Module root exporting nvml, amdsmi, statvfs
│   │   ├── amdsmi.zig          # AMD SMI (ROCm) C header bindings
│   │   ├── nvml.zig            # NVIDIA NVML (CUDA) C header bindings
│   │   └── statvfs.zig         # POSIX statvfs C wrapper for filesystem sizing
│   │
│   ├── config/                 # Waybar JSON/JSONC Configuration System
│   │   ├── root.zig            # Config finder and exports
│   │   ├── bar_config.zig      # BarConfig parser, per-output matching, settings
│   │   ├── jsonc.zig           # JSONC parser stripping comments and trailing commas
│   │   └── default/            # Built-in fallback config.jsonc and style.css
│   │
│   ├── gtk/                    # GTK4 & Layer-Shell C Bindings
│   │   └── c.zig               # C imports: GTK4, GDK4, GLib/GIO, gtk4-layer-shell
│   │
│   ├── modules/                # Status bar module implementations
│   │   ├── root.zig            # ModuleHandle factory (`createModule`)
│   │   ├── base.zig            # BaseModule GTK wrapper (buttons, labels, actions)
│   │   ├── clock.zig           # Date and time display
│   │   ├── cpu.zig             # CPU percentage monitor
│   │   ├── memory.zig          # RAM and swap usage monitor
│   │   ├── temperature.zig     # Hardware thermal sensor monitor
│   │   ├── disk.zig            # Filesystem usage & mount stats
│   │   ├── network.zig         # Ethernet / Wi-Fi metrics, IP, bandwidth
│   │   ├── battery.zig         # Battery percentage, charging state (sysfs/UPower)
│   │   ├── backlight.zig       # Display brightness monitor
│   │   ├── workspaces.zig      # Wayland workspaces (Hyprland, Sway, Niri, River, etc.)
│   │   ├── tray.zig            # System tray via StatusNotifierItem (SNI) D-Bus
│   │   ├── window.zig          # Active window title display
│   │   ├── wireplumber.zig     # Audio volume / mute status (PipeWire/WirePlumber)
│   │   ├── mpris.zig           # Media player controls and track metadata
│   │   ├── bluetooth.zig       # Bluetooth status & connected devices
│   │   ├── group.zig           # Nested / collapsible module groups (drawers)
│   │   ├── sliders.zig         # Interactive slider widgets (volume, brightness)
│   │   ├── idle_inhibitor.zig  # Wayland idle inhibitor toggle
│   │   ├── power_profiles.zig  # power-profiles-daemon switcher
│   │   ├── upower.zig          # UPower battery devices
│   │   ├── load.zig            # System load averages
│   │   ├── user.zig            # Current user and uptime
│   │   ├── image.zig           # Static / dynamic GTK image widget
│   │   ├── gamemode.zig        # Feral GameMode active status
│   │   ├── systemd_failed.zig  # Systemd failed units monitor
│   │   ├── keyboard_state.zig  # CapsLock / NumLock indicator
│   │   ├── privacy.zig         # Microphone / camera active privacy indicators
│   │   ├── compositor_modes.zig# Submap / mode indicators (Hyprland, Sway, Mango, River)
│   │   ├── taskbar.zig         # Foreign toplevel taskbar
│   │   ├── mpd.zig             # Music Player Daemon client
│   │   ├── jack.zig            # JACK audio server status
│   │   ├── cava.zig            # CAVA audio visualizer
│   │   └── custom.zig          # Custom user scripts (streaming or periodic)
│   │
│   ├── sysinfo/                # System metric readers and domain logic
│   │   ├── root.zig            # Root aggregator of sysinfo collectors
│   │   ├── backlight/          # Reads `/sys/class/backlight`
│   │   ├── battery/            # Reads sysfs battery data or UPower
│   │   ├── bluetooth/          # Interacts with BlueZ via plume D-Bus
│   │   ├── cpu/                # Parses `/proc/stat` & `/sys/devices/system/cpu`
│   │   ├── disk/               # Parses `/proc/mounts` and queries `statvfs`
│   │   ├── fan/                # Reads `/sys/class/hwmon` fan inputs
│   │   ├── gpu/                # Abstraction layer for NVML, AMD SMI, DRM
│   │   ├── memory/             # Parses `/proc/meminfo`
│   │   ├── mpris/              # Interacts with org.mpris.MediaPlayer2
│   │   ├── network/            # Parses `/proc/net/dev`, `/proc/net/route`, DNS
│   │   ├── pipewire/           # Connects to PipeWire / PulseAudio interfaces
│   │   ├── temperature/        # Reads `/sys/class/thermal` and `/sys/class/hwmon`
│   │   ├── updates/            # Queries package managers (pacman, apt, etc.)
│   │   └── common/             # Sysfs integer, milli, and string helpers
│   │
│   └── utils/                  # Shared utilities
│       ├── root.zig            # Exports AppContext, Replacer, Json, Process, etc.
│       ├── context.zig         # AppContext singleton holding io, gpa, environ_map
│       ├── replacer/           # Dynamic placeholder engine (`{icon}`, `{usage}`)
│       ├── json/               # Streaming JSON encoder
│       ├── process/            # Process iterator, helpers, exec
│       └── watcher/            # Signal watcher primitives
│
├── build.zig                   # Zig build script (GTK4 & layer-shell pkg-config)
├── build.zig.zon               # Dependencies (plume D-Bus client library)
├── LICENSE                     # GNU General Public License v3.0
└── README.md                   # Project overview & quick start
```
