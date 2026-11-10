![vergebar](https://img.shields.io/badge/vergebar-gray?style=for-the-badge&logo=zig&logoColor=orange)
![License](https://img.shields.io/badge/License-GPL--3.0-orange?style=for-the-badge)
![Stars](https://img.shields.io/github/stars/lumexren/vergebar?style=for-the-badge&color=DAA520)
![Issues](https://img.shields.io/github/issues/lumexren/vergebar?style=for-the-badge)
![Last Commit](https://img.shields.io/github/last-commit/lumexren/vergebar?style=for-the-badge&color=F7A41D)

A lightweight Wayland status bar written in Zig using GTK4 and gtk4-layer-shell, with Waybar configuration and style compatibility.

## Dependencies

- **Zig** `>= 0.18.0-dev`
- **GTK4**
- **gtk4-layer-shell**
- **PipeWire**

```bash
# Arch Linux
sudo pacman -S gtk4 gtk4-layer-shell pipewire pkgconf

# Fedora
sudo dnf install gtk4-devel gtk4-layer-shell-devel pipewire-devel pkgconf-pkg-config

# Ubuntu / Debian
sudo apt install libgtk-4-dev libgtk4-layer-shell-dev libpipewire-0.3-dev pkg-config
```

## Build & Install

```bash
git clone https://github.com/lumexren/vergebar.git
cd vergebar

# Optimized release build
zig build -Doptimize=ReleaseFast

# Or minimal binary size
zig build -Doptimize=ReleaseSmall
```

The compiled binary will be placed at `zig-out/bin/vergebar`.

## Usage

```bash
# Automatic config discovery (~/.config/vergebar/ or ~/.config/waybar/)
vergebar

# Custom config and style
vergebar -c path/to/config.jsonc -s path/to/style.css

# Validate configuration without launching windows
vergebar --validate-config -c path/to/config.jsonc -s path/to/style.css

# List available built-in modules
vergebar --list-modules
```

## IPC Client (`vergebar msg`)

Control a running vergebar daemon over UNIX domain sockets:

```bash
vergebar msg toggle         # Toggle bar visibility
vergebar msg reload-style   # Reload CSS styles
vergebar msg reload-config  # Reload config and rebuild bar
vergebar msg signal <num>   # Send real-time signal to custom modules
vergebar msg list-bars      # List running bar instances
vergebar msg quit           # Exit vergebar
```

## Supported Modules

| Category | Modules |
| :--- | :--- |
| **Compositor & Window** | `workspaces`, `window`, `taskbar` (`wlr/taskbar`), `compositor_modes` (`hyprland/*`, `sway/*`, `river/*`, `mango/*`) |
| **Hardware & Performance** | `cpu`, `memory`, `disk`, `temperature`, `fan`, `load`, `gpu` |
| **Audio & Media** | `wireplumber`, `sliders` (volume/brightness), `mpris`, `cava`, `mpd`, `jack` |
| **Connectivity & Power** | `network`, `bluetooth`, `battery`, `power-profiles-daemon`, `upower`, `backlight` |
| **System & Desktop** | `clock`, `tray`, `dnd` (`notifications`), `clipboard`, `keyboard-state`, `privacy`, `weather`, `updates`, `gamemode`, `systemd-failed-units`, `user`, `group`, `custom/*` |

---

<div align="center">

**Built with ❤️ by lumexren**

*Star ⭐ this repo if you find it useful!*

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](./LICENSE) for details.

</div>
