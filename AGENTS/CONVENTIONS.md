# Coding Conventions & Zig Idioms

This document details the code conventions, memory safety guidelines, and architectural rules applied throughout `vergebar`.

---

## 1. Function Parameter Ordering Rule (Strict)

### The Primary Rule: `Io` First, then `Allocator`
Any function or constructor that requires `Io` (or `std.Io`) **must** declare `io` as its **first argument**, followed immediately by `allocator`:

```zig
// ❌ Incorrect:
pub fn create(allocator: Allocator, io: std.Io, name: []const u8, ...) !*MyModule
pub fn create(allocator: Allocator, name: []const u8, settings: ModuleSettings, io: std.Io) !*MyModule
pub fn createModule(allocator: Allocator, io: std.Io, name: []const u8, config: *BarConfig) ?ModuleHandle

// ✅ Correct:
pub fn create(io: std.Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*MyModule
pub fn create(io: std.Io, allocator: Allocator, config: *BarConfig, monitor: ?*gtk.GdkMonitor, ...) !*Bar
pub fn createModule(io: std.Io, allocator: Allocator, name: []const u8, config: *BarConfig) ?ModuleHandle
pub fn getSystemDnsServers(io: Io, allocator: Allocator) ![][]const u8
pub fn runCommandCapture(io: Io, allocator: Allocator, argv: []const []const u8) ![]u8
pub fn findExecutable(io: Io, allocator: Allocator, environ_map: *Map, exe_name: []const u8) !?[]u8
```

### Method Signatures (With Receiver)
For methods that take a struct instance receiver (`this` or `self`), the receiver comes first, followed by `io`, then `allocator`:

```zig
// ✅ Correct:
pub fn getCmdline(this: Process, io: Io, allocator: Allocator) ![]u8
pub fn getEnviron(this: Process, io: Io, allocator: Allocator) ![]u8
pub fn getCwd(this: Process, io: Io, allocator: Allocator) ![]u8
```

---

## 2. Standard Library Import Aliasing

To maintain consistent and clean codebase idioms, **never** reference `std.<Type>` or `std.<namespace>.<func>` inline within function or module logic when an alias can be used.

Always extract and alias required standard library namespaces and types at the top of the file:

```zig
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const posix = std.posix;
const os = std.os;
const linux = os.linux;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
```

---

## 3. Result Location Type Inference (`var X: Type = .init(...)`)

Declare variables using explicit type annotations paired with inferred member initializers:

```zig
// ✅ Standard idiom:
var replacer: Replacer = .init(gpa);
var json: Json = .init(gpa);
var cpu: CPU = .init(io, allocator);

// ❌ Avoid omitting explicit types or using redundant Type prefixes:
var replacer = Replacer.init(gpa);
var cpu = sysinfo.CPU.init(io, allocator);
```

### Exception: Binary `catch` Expressions
When an initializer returns an error union (`!T`) and is handled inline with `catch`, Zig's type inference does not penetrate the binary `catch` operator (treating `.init` as `@EnumLiteral`). Keep the explicit receiver in those cases:

```zig
var conn: Connection = Connection.init(io, gpa, .System, &env) catch |err| { ... };
```

---

## 4. Memory Management & GTK Lifecycle

`vergebar` is a long-running status bar process. Memory safety and leak-free execution are critical:

### Module Allocations
- Modules are heap-allocated structs wrapping a `BaseModule`:
  ```zig
  const self = try allocator.create(MyModule);
  errdefer allocator.destroy(self);
  
  self.base = try BaseModule.init(allocator, name, "mymodule", on_click, on_click_middle, on_click_right);
  errdefer self.base.deinit();
  ```
- In `deinit(self: *MyModule)`:
  1. Remove any registered GLib timeout timers (`g_source_remove(self.timer_id)`).
  2. Free any duplicated strings owned by the module (`format`, `icon`, etc.).
  3. Call `self.base.deinit()`.
  4. Destroy the module struct (`allocator.destroy(self)`).

### GTK4 Widget Lifecycle
- Widgets are managed by GTK reference counting. Appending a widget to a GTK box (`gtk_box_append`) transfers / shares reference ownership with the parent container.
- Signal handlers must use `@ptrCast(&callback)` and pass `self` as the `user_data` pointer.
- Signal callbacks executed from GTK/GLib must be `callconv(.c)`.

---

## 5. Signal Handling Architecture

`vergebar` uses a self-pipe pattern for asynchronous signal dispatch:
1. Signal handlers (`SIGUSR1`, `SIGUSR2`, `SIGRTMIN+n`) write signal numbers to a non-blocking POSIX pipe.
2. A GLib timer (`gtk.g_timeout_add(50, ...)`) checks the read end of the pipe on the GTK main thread.
3. This eliminates signal-handler reentrancy bugs and allows safely calling GTK functions in response to external signals.

- `SIGUSR1`: Toggles bar visibility.
- `SIGUSR2`: Reloads CSS stylesheets.
- `SIGRTMIN+n` (34..64): Dispatches to custom modules matching `on-click` / real-time signal triggers.

---

## 6. Naming Conventions

| Identifier | Convention | Example |
| :--- | :--- | :--- |
| Structs, Enums, Types | `PascalCase` | `BarConfig`, `CpuModule`, `ModuleHandle`, `RouteInfo` |
| Functions, Methods | `camelCase` | `createModule`, `getDefaultRoute`, `updateText` |
| Variables, Fields, Params | `snake_case` | `update_interval`, `warning_threshold`, `allocator` |
| Constants | `UPPER_SNAKE_CASE` or `camelCase` (types) | `VERSION`, `PULSE_SERVICE`, `FALLBACK_DNS` |

---

## 7. License Headers & Code Formatting

### License Header
Every Zig source file must begin with the standard GPL-3.0 header:

```zig
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
```

### Formatting
Always run `zig fmt .` before finalizing changes. Ensure consistent 4-space indentation and no trailing whitespace.
