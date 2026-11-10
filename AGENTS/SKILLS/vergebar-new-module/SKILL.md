---
name: vergebar-new-module
description: >-
  Scaffold a new vergebar status bar module adhering strictly to Vergebar architecture,
  Zig 0.18.x conventions, memory management, and configuration registration.
---

# Vergebar New Module Scaffold Skill

Use this procedure when creating or adding a new status bar module to Vergebar.

## 1. Module Design Guidelines
1. **Module Location**: Create `src/modules/<name>/root.zig`.
2. **Standard Imports & Types**:
   - Receiver convention: Use `this: *<Name>Module`.
   - Function parameter order: `(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings)`.
   - License Header: GPL-3.0 header at the top.
   - Anonymous Invocations: Use `.init(...)`, `.{ ... }`, `.compile(...)` with result location type inference.
   - Clean Code: Never add redundant or self-evident inline comments.

## 2. Standard Module Skeleton
```zig
// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of vergebar.
//
// Copyright (c) 2026 lumexren

const SampleModule = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const gtk = @import("gtk");
const BaseModule = @import("../base/root.zig");
const ModuleSettings = @import("utils").Config.ModuleSettings;
const Replacer = @import("utils").Replacer;
const Template = @import("utils").Template;

base: *BaseModule,
allocator: Allocator,
replacer: Replacer,
template: Template,
template_tooltip: ?Template = null,
format: []const u8,
interval_sec: u32,
timer_id: u32 = 0,

pub fn create(io: Io, allocator: Allocator, name: []const u8, settings: ModuleSettings) !*SampleModule {
    const this = try allocator.create(SampleModule);
    errdefer allocator.destroy(this);

    const base_mod: *BaseModule = try .initFromSettings(io, allocator, name, "sample", settings);
    errdefer base_mod.deinit();

    const format_str = settings.getString("format") orelse "{text}";
    const interval = @as(u32, @intCast(settings.getInt("interval") orelse 5));

    this.* = .{
        .base = base_mod,
        .allocator = allocator,
        .replacer = .init(allocator),
        .template = try .compile(allocator, format_str),
        .template_tooltip = if (base_mod.tooltip_format) |tf| Template.compile(allocator, tf) catch null else null,
        .format = try allocator.dupe(u8, format_str),
        .interval_sec = interval,
    };

    this.update();
    this.timer_id = gtk.g_timeout_add_seconds(this.interval_sec, @ptrCast(&onTimeout), this);

    return this;
}

pub fn deinit(this: *SampleModule) void {
    if (this.timer_id != 0) {
        _ = gtk.g_source_remove(this.timer_id);
        this.timer_id = 0;
    }
    this.template.deinit();
    if (this.template_tooltip) |*tt| tt.deinit();
    this.replacer.deinit();
    this.allocator.free(this.format);
    this.base.deinit();
    this.allocator.destroy(this);
}

pub fn update(this: *SampleModule) void {
    this.replacer.clear();
    this.replacer.addKey("text", "Sample Text") catch {};

    var render_buf: [128]u8 = undefined;
    const rendered = this.template.renderBuf(&this.replacer, &render_buf) catch this.format;
    this.base.setText(rendered);
}

fn onTimeout(user_data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const this: *SampleModule = @ptrCast(@alignCast(user_data orelse return 0));
    this.update();
    return 1;
}
```

## 3. Registering the Module
1. In `src/modules/root.zig`:
   - Add module export: `pub const SampleModule = @import("sample/root.zig");`
   - Add mapping to `createModule`:
     ```zig
     } else if (mem.eql(u8, name, "sample") or mem.startsWith(u8, name, "sample#")) {
         const m = try SampleModule.create(io, allocator, name, settings);
         return .{ .ptr = m, .vtable = &ModuleVTable.from(SampleModule) };
     ```
2. In `examples/config.jsonc`:
   - Document sample configuration block for the new module.
