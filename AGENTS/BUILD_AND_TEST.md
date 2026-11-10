# Build & Test Guide

This document covers compiling, testing, running, and packaging **`vergebar`**.

---

## 🛠️ Toolchain Requirements

- **Zig Version:** Requires **`0.18.0-dev`** (targeting modern `std.Io` / `std.process` APIs).
- **GTK4:** Requires `gtk4` development packages.
- **gtk4-layer-shell:** Requires `gtk4-layer-shell` (`gtk4-layer-shell-0` pkg-config module).
- **PipeWire:** Requires `pipewire-0.3` development headers.

### Installing Dependencies

#### Arch Linux
```bash
sudo pacman -S gtk4 gtk4-layer-shell pipewire pkgconf
```

#### Fedora
```bash
sudo dnf install gtk4-devel gtk4-layer-shell-devel pipewire-devel pkgconf-pkg-config
```

#### Ubuntu / Debian
```bash
sudo apt install libgtk-4-dev libgtk4-layer-shell-dev libpipewire-0.3-dev pkg-config
```

---

## 🏗️ Build Commands

### Standard Build (Debug)
Compiles `vergebar` executable into `zig-out/bin/vergebar`:
```bash
zig build
```

### Production / Release Builds
```bash
# Maximum runtime performance:
zig build -Doptimize=ReleaseFast

# Minimal binary size:
zig build -Doptimize=ReleaseSmall
```

---

## 🧪 Running Tests

The test suite validates the core utility modules and sysinfo collectors:

```bash
# Run all unit tests
zig build test

# Run tests with complete summary
zig build test --summary all
```

---

## 🚀 Running vergebar

```bash
# Run with automatic config discovery:
# Looks for ~/.config/vergebar/config.jsonc then ~/.config/waybar/config.jsonc
./zig-out/bin/vergebar

# Run with custom configuration and stylesheet:
./zig-out/bin/vergebar -c examples/config.jsonc -s examples/style.css

# Validate configuration without launching GUI / Wayland bars:
./zig-out/bin/vergebar --validate-config -c examples/config.jsonc -s examples/style.css

# List all available built-in modules:
./zig-out/bin/vergebar --list-modules

# Export built-in default configuration JSONC or stylesheet CSS:
./zig-out/bin/vergebar --dump-default-config > ~/.config/vergebar/config.jsonc
./zig-out/bin/vergebar --dump-default-style > ~/.config/vergebar/style.css

# View command-line help:
./zig-out/bin/vergebar --help
```

---

## 📡 IPC Client (`vergebar msg`)

Vergebar includes an instant UNIX domain socket IPC interface:

```bash
# Toggle visibility:
./zig-out/bin/vergebar msg toggle

# Reload CSS styles without rebuilding widgets:
./zig-out/bin/vergebar msg reload-style

# Re-read configuration and reconstruct bars:
./zig-out/bin/vergebar msg reload-config

# Trigger a custom module update signal:
./zig-out/bin/vergebar msg signal 1

# List active bars and their geometry:
./zig-out/bin/vergebar msg list-bars

# Cleanly exit vergebar daemon:
./zig-out/bin/vergebar msg quit
```

---

## 🔍 Code Formatting

Always ensure all Zig files adhere to the project style:
```bash
zig fmt .
```
