# AI Agent Guidelines & Codebase Knowledge Base

Welcome to the **`vergebar`** codebase knowledge base for AI agents. This directory (`AGENTS/`) provides a structured, high-signal guide to understanding, developing, debugging, and extending this project.

---

## 🧭 Navigation Index

| Document | Purpose |
| :--- | :--- |
| **[ARCHITECTURE.md](./ARCHITECTURE.md)** | Core bar architecture, Wayland layer-shell lifecycle, GTK4 integration, and data flow pipeline. |
| **[PROJECT_STRUCTURE.md](./PROJECT_STRUCTURE.md)** | Directory tree breakdown, file roles, and module/sysinfo taxonomy. |
| **[BUILD_AND_TEST.md](./BUILD_AND_TEST.md)** | Toolchain versioning (Zig 0.17.0, GTK4, gtk4-layer-shell), build options, and test suite. |
| **[CONVENTIONS.md](./CONVENTIONS.md)** | Coding style, parameter ordering (`io: std.Io, allocator: Allocator`), memory management, and GTK idioms. |
| **[SUBSYSTEMS.md](./SUBSYSTEMS.md)** | Deep dives into `Bar`, `BarConfig` (JSONC), `BaseModule`, `Replacer`, `sysinfo`, and `AppContext`. |
| **[CREATING_MODULES.md](./CREATING_MODULES.md)** | Step-by-step tutorial on implementing a new status bar module in `vergebar`. |

---

## ⚡ Project Overview

- **Project:** `vergebar`
- **Language:** **Zig** (`0.17.0`)
- **Toolkit:** **GTK4** (`gtk4-layer-shell`)
- **License:** GNU General Public License v3.0 (GPL-3.0-only)
- **Author:** lumexren
- **Goal:** High-performance, lightweight, memory-safe Waybar-compatible status bar for Wayland written in Zig, built on GTK4 and gtk4-layer-shell, incorporating the fast native monitoring engines of `zig-waybar-contrib`.
- **Key Philosophy:**
  - **Low Memory Footprint:** ~8–15 MB RSS compared to Waybar's ~35–70 MB RSS.
  - **Zero / Minimal Idle Overhead:** Event-driven updates via GLib event loop, D-Bus signal subscriptions, and signal dispatching (`SIGUSR1`, `SIGUSR2`, `SIGRTMIN+n`).
  - **Strict Function Argument Ordering:** Any function requiring I/O must place `io: std.Io` as the first argument, followed immediately by `allocator: Allocator` (e.g., `pub fn create(io: std.Io, allocator: Allocator, ...)`).
  - **Drop-in Compatibility:** Direct support for Waybar `config.jsonc` and `style.css` configurations.

---

## 🚀 Quick Commands for Agents

```bash
# Check Zig version (0.17.0)
zig version

# Build vergebar (Debug)
zig build

# Build optimized release binary
zig build -Doptimize=fast # or -Doptimize=small

# Run test suite
zig build test

# Run tests with full summary
zig build test --summary all

# Format all code
zig fmt .
```
