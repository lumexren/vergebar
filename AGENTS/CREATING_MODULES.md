# Creating a New Vergebar Module

This guide provides a comprehensive step-by-step tutorial for implementing a new status bar module in **`vergebar`**.

---

## Overview of Steps

1. **Implement Module Struct:** Create `src/modules/<name>/root.zig` wrapping `BaseModule`.
2. **Implement Parameter Ordering:** Ensure `create()` takes `(io: std.Io, allocator: Allocator, ...)` if I/O is needed.
3. **Set Up Update Timer:** Register periodic updates with `gtk.g_timeout_add_seconds`.
4. **Register in Factory:** Add module branch in `src/modules/root.zig`'s `createModule`.
5. **Configure & Style:** Test with `config.jsonc` and `style.css`.

---

## Step 1: Implement the Module (`src/modules/example/root.zig`)

```zig
// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of vergebar.
//
// Copyright (c) 2026 lumexren

const ExampleModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");

const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;

base: *BaseModule,
allocator: Allocator,
format: []const u8,
interval_sec: u32,
timer_id: u32 = 0,

// ✅ Note: `io` must precede `allocator` whenever Io is required!
pub fn create(
    io: Io,
    allocator: Allocator,
    name: []const u8,
    settings: ModuleSettings,
) !*ExampleModule {
    const this = try allocator.create(ExampleModule);
    errdefer allocator.destroy(this);

    // Inferred anonymous initialization (Result Location Type Inference):
    this.base = try .initFromSettings(
        io,
        allocator,
        name,
        "example",
        settings,
    );
    errdefer this.base.deinit();

    this.allocator = allocator;
    this.format = try allocator.dupe(u8, settings.getOr([]const u8, "format", "Example: {val}"));
    this.interval_sec = settings.getOr(u32, "interval", 2);

    // Run initial update
    this.update();

    // Register periodic timer with GLib
    this.timer_id = gtk.g_timeout_add_seconds(
        this.interval_sec,
        @ptrCast(&onTimeout),
        this,
    );

    return this;
}

pub fn deinit(this: *ExampleModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
    }
    this.allocator.free(this.format);
    
    // Always cache the allocator prior to calling this.base.deinit() to prevent use-after-free
    const alloc = this.base.allocator;
    this.base.deinit();
    alloc.destroy(this);
}

pub fn update(this: *ExampleModule) void {
    var buf: [128]u8 = undefined;
    const rendered = std.mem.print(&buf, "Example: {d}", .{42}) catch return;

    this.base.setText(rendered);
    this.base.setTooltip("Tooltip details here");
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *ExampleModule = @ptrCast(@alignCast(user_data));
    this.update();
    return 1; // 1 = continue periodic execution
}
```

---

## Step 2: Register in `src/modules/root.zig`

Open `src/modules/root.zig` and import your new module:

```zig
pub const ExampleModule = @import("example/root.zig");
```

Inside `pub fn createModule`:

```zig
    } else if (mem.eql(u8, name, "example")) {
        const mod = ExampleModule.create(io, allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *ExampleModule = @ptrCast(@alignCast(ptr));
                    m.deinit();
                }
            }.deinit,
        };
```

---

## Step 3: Test Configuration & Styling

Add your module to `examples/config.jsonc`:

```jsonc
{
  "modules-right": ["example"],

  "example": {
    "format": "Example: {val}",
    "interval": 2,
    "on-click": "notify-send 'Clicked example module!'"
  }
}
```

Add CSS styles in `examples/style.css`:

```css
#example {
  background-color: #2e3440;
  color: #eceff4;
  padding: 0 10px;
}

#example.warning {
  background-color: #ebcb8b;
  color: #2e3440;
}
```

---

## Step 4: Verify Build & Run

```bash
# Verify compilation
zig build

# Run unit tests
zig build test

# Launch with test config
./zig-out/bin/vergebar -c examples/config.jsonc -s examples/style.css
```
