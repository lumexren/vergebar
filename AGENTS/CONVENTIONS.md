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
For methods that take a struct instance receiver (`this`), the receiver comes first, followed by `io`, then `allocator`:

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

## 3. Result Location Type Inference & Anonymous Invocations

In Zig, whenever the target destination type of an assignment, struct field, variable declaration, function parameter, or return expression is already known, omit redundant explicit type qualifiers and utilize anonymous invocations (`.init(...)`, `.{ ... }`, `.fromString(...)`, etc.):

### 3.1. Struct Member & Field Assignments
When assigning to a struct field whose type is declared on the struct definition, never repeat the type name:

```zig
// ✅ Correct:
this.base = try .initFromSettings(io, allocator, name, "cpu", settings);
this.replacer = .init(allocator);
this.template = try .compile(allocator, fmt_str);
this.cpu = .init(io, allocator);
this.memory = .init(io);
this.temp = .init(io, allocator, null);
this.items = .empty;
this.menu_actions = .init(allocator);

// ❌ Redundant / Anti-pattern:
this.base = try BaseModule.initFromSettings(io, allocator, name, "cpu", settings);
this.replacer = Replacer.init(allocator);
this.template = try Template.compile(allocator, fmt_str);
this.cpu = sysinfo.CPU.init(io, allocator);
this.memory = sysinfo.Memory.init(io);
```

### 3.2. Variable Declarations with Explicit Types
When declaring local variables with explicit types, invoke the initializer anonymously:

```zig
// ✅ Correct:
var replacer: Replacer = .init(allocator);
var icons_map: std.StringHashMap([]const u8) = .init(allocator);
var arena: ArenaAllocator = .init(allocator);
var out_list: ArrayList([]const u8) = .empty;
var watcher: Watcher = try .init();
const shared: *SharedArena = try .create(allocator);

// ❌ Redundant / Anti-pattern:
var replacer: Replacer = Replacer.init(allocator);
var icons_map: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(allocator);
var arena: ArenaAllocator = ArenaAllocator.init(allocator);
```

### 3.3. Anonymous Struct Literals (`.{ ... }`)
When the target type is already declared or known by the destination:

```zig
// ✅ Correct:
var adapter: AdapterInfo = .{
    .path = try allocator.dupe(u8, path),
    .name = try allocator.dupe(u8, name),
};
const header: Header = .{
    .id = query_id,
    .flags = 0x0100,
};
const watcher_vtable: gtk.GDBusInterfaceVTable = .{
    .method_call = &onWatcherMethodCall,
    ...
};
return .{}; // when returning a known struct type T

// ❌ Redundant / Anti-pattern:
var adapter = AdapterInfo{
    .path = try allocator.dupe(u8, path),
    ...
};
```

### 3.4. Enum / Factory Methods (`.fromString`, `.fromBytes`, etc.)
When the receiving type or argument parameter type is known:

```zig
// ✅ Correct:
cfg.layer = .fromString(val.string);
cfg.position = .fromString(val.string);
gpu.setBackend(.fromString(backend_str));
const parsed: Header = .fromBytes(&bytes);

// ❌ Redundant:
cfg.layer = Layer.fromString(val.string);
cfg.position = Position.fromString(val.string);
gpu.setBackend(sysinfo.GPU.Backend.fromString(backend_str));
```

### 3.5. Exception: Binary `catch` Expressions
When an initializer returns an error union (`!T`) and is handled with an inline binary `catch`, Zig parses `.init` as an `@EnumLiteral` before peer type resolution resolves the error union payload. In those specific inline `catch` cases, retain the explicit receiver:

```zig
// Required with inline catch:
var conn: Connection = Connection.init(io, gpa, .System, &env) catch |err| { ... };

// But with 'try', anonymous invocation works seamlessly:
this.base = try .initFromSettings(io, allocator, ...);
this.template = try .compile(allocator, fmt_str);
var watcher: Watcher = try .init();
```

---

## 4. Memory Management & GTK Lifecycle

`vergebar` is a long-running status bar process. Memory safety and leak-free execution are critical:

### Module Allocations & Deinit Order (Preventing Use-After-Free)
- Modules are heap-allocated structs wrapping a `BaseModule`:
  ```zig
  const this = try allocator.create(MyModule);
  errdefer allocator.destroy(this);
  
  this.base = try .initFromSettings(io, allocator, name, "mymodule", settings);
  errdefer this.base.deinit();
  ```
- In `deinit(this: *MyModule)`:
  1. Remove any registered GLib timeout timers (`g_source_remove(this.timer_id)`).
  2. Free any module-owned resources, templates, strings, and threads (`this.template.deinit()`, etc.).
  3. **Critical Lifecycle Rule:** If the module struct is freed using `this.base.allocator`, you **must** cache the allocator before calling `this.base.deinit()`:
     ```zig
     // ✅ Correct (Safe against use-after-free):
     const alloc = this.base.allocator;
     this.base.deinit();
     alloc.destroy(this);

     // ❌ CRASH (Use-after-free):
     this.base.deinit();
     this.base.allocator.destroy(this); // Reading allocator from freed this.base memory!
     ```

### GTK4 Widget Lifecycle
- Widgets are managed by GTK reference counting. Appending a widget to a GTK box (`gtk_box_append`) transfers / shares reference ownership with the parent container.
- Signal handlers must use `@ptrCast(&callback)` and pass `this` as the `user_data` pointer.
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

---

## 8. No Deprecated Functions & APIs

Strict adherence to current language, runtime, and library APIs is required:
1. **No Deprecated Standard Library APIs**:
   - Always target the current compiler version (`0.18.x-dev`). Never use deprecated or phased-out functions (e.g. use `std.mem.printSentinel` instead of deprecated wrappers).
   - Use current slice/string manipulation idioms (`mem.printSentinel`, `fmt.bufPrint`, etc.) without resorting to outdated legacy patterns.
2. **No Deprecated GTK / GIO APIs**:
   - Only call active and supported GTK4 and GLib/GIO functions. Do not use symbols marked `G_DEPRECATED` or `GTK_DEPRECATED`.
3. **Documentation Integrity & Explanatory Comments**:
   - Avoid redundant, trivial inline comments (e.g. `// Event-driven...`). Write clear, self-documenting code.
