# Build & Test Guide

This document covers compiling, testing, running, and packaging **`vergebar`**.

---

## 🛠️ Toolchain Requirements

- **Zig Version:** Requires **`0.17.0`**.
- **GTK4:** Requires `gtk4` development packages.
- **gtk4-layer-shell:** Requires `gtk4-layer-shell` (`gtk4-layer-shell-0` pkg-config module).

### Installing Dependencies

#### Arch Linux
```bash
sudo pacman -S gtk4 gtk4-layer-shell pkgconf
```

#### Fedora
```bash
sudo dnf install gtk4-devel gtk4-layer-shell-devel pkgconf-pkg-config
```

#### Ubuntu / Debian
```bash
sudo apt install libgtk-4-dev libgtk4-layer-shell-dev pkg-config
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
zig build -Doptimize=fast

# Minimal binary size:
zig build -Doptimize=small
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

# View command-line help:
./zig-out/bin/vergebar --help
```

---

## 🔍 Code Formatting

Always ensure all Zig files adhere to the project style:
```bash
zig fmt .
```
