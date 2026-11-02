# Creating a New Vergebar Module

This guide provides a comprehensive step-by-step tutorial for implementing a new status bar module in **`vergebar`**.

---

## Overview of Steps

1. **Implement Module Struct:** Create `src/modules/<name>.zig` wrapping `BaseModule`.
2. **Implement Parameter Ordering:** Ensure `create()` takes `(io: std.Io, allocator: Allocator, ...)` if I/O is needed.
3. **Set Up Update Timer:** Register periodic updates with `gtk.g_timeout_add_seconds`.
4. **Register in Factory:** Add module branch in `src/modules/root.zig`'s `createModule`.
5. **Configure & Style:** Test with `config.jsonc` and `style.css`.

---

## Step 1: Implement the Module (`src/modules/example.zig`)

```zig
// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of vergebar.
//
// Copyright (c) 2026 lumexren

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const gtk = @import("gtk");

const BaseModule = @import("base.zig").BaseModule;
const ModuleSettings = @import("../config/bar_config.zig").ModuleSettings;
const sysinfo = @import("../sysinfo/root.zig");

pub const ExampleModule = struct {
    base: BaseModule,
    allocator: Allocator,
    io: std.Io,
    format: []const u8,
    interval_sec: u32,
    timer_id: u32 = 0,

    // ✅ Note: `io` must precede `allocator` whenever Io is required!
    pub fn create(
        io: std.Io,
        allocator: Allocator,
        name: []const u8,
        settings: ModuleSettings,
    ) !*ExampleModule {
        const self = try allocator.create(ExampleModule);
        errdefer allocator.destroy(self);

        const on_click = settings.getString("on-click");
        const on_click_middle = settings.getString("on-click-middle");
        const on_click_right = settings.getString("on-click-right");

        self.base = try BaseModule.init(
            allocator,
            name,
            "example",
            on_click,
            on_click_middle,
            on_click_right,
        );
        errdefer self.base.deinit();

        self.allocator = allocator;
        self.io = io;
        self.format = try allocator.dupe(u8, settings.getString("format") orelse "Example: {val}");
        self.interval_sec = @intCast(settings.getInt("interval") orelse 2);

        // Run initial update
        self.update();

        // Register periodic timer with GLib
        self.timer_id = gtk.g_timeout_add_seconds(
            self.interval_sec,
            @ptrCast(&onTimeout),
            self,
        );

        return self;
    }

    pub fn deinit(self: *ExampleModule) void {
        if (self.timer_id != 0) {
            _ = gtk.g_source_remove(self.timer_id);
        }
        self.allocator.free(self.format);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *ExampleModule) void {
        var buf: [128]u8 = undefined;
        const rendered = std.mem.print(&buf, "Example: {d}", .{42}) catch return;

        self.base.setText(rendered);
        self.base.setTooltip("Tooltip details here");
    }

    fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
        const self: *ExampleModule = @ptrCast(@alignCast(user_data));
        self.update();
        return 1; // 1 = continue periodic execution
    }
};
```

---

## Step 2: Register in `src/modules/root.zig`

Open `src/modules/root.zig` and import your new module:

```zig
pub const example = @import("example.zig");
```

Inside `pub fn createModule`:

```zig
    } else if (mem.eql(u8, name, "example")) {
        const mod = example.ExampleModule.create(io, allocator, name, settings) catch return null;
        return .{
            .widget = mod.base.button,
            .ptr = mod,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const m: *example.ExampleModule = @ptrCast(@alignCast(ptr));
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
