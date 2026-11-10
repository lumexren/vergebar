---
name: vergebar-c-bindings
description: >-
  Declare lightweight, type-safe C-ABI extern functions and opaque handles
  without bloated header imports or build bloat.
---

# Vergebar C Bindings Skill

Use this procedure when binding external C library APIs (GTK4, GIO, PipeWire, libgudev, etc.) into `src/bindings/`.

## 1. Principles
1. **No `@cInclude` in Core Modules**: Keep compilation times fast by using explicit `extern "c"` declarations.
2. **Opaque Type Handles**: Use `pub const Type = anyopaque;` or `pub const Type = opaque {};` for foreign struct pointers.
3. **Null-Terminated Strings**: Explicitly type C string parameters as `?[*:0]const u8` or `[*:0]const u8`.
4. **No Deprecated Symbols**: Only bind and call non-deprecated API functions.

## 2. Standard Binding Template
```zig
// In src/bindings/<lib>.zig:
pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;

pub const GtkWidget = anyopaque;
pub const GtkBox = anyopaque;

pub extern "c" fn gtk_box_new(orientation: c_uint, spacing: c_int) ?*GtkWidget;
pub extern "c" fn gtk_box_append(box: ?*GtkBox, child: ?*GtkWidget) void;
```

## 3. Invocation Conventions
- When passing formatted strings into C functions expecting null-terminated pointers:
  ```zig
  var buf: [128]u8 = undefined;
  const str = mem.printSentinel(&buf, "Value: {d}", .{val}, 0) catch return;
  gtk.gtk_button_new_with_label(str.ptr);
  ```
- Always respect ownership and memory unreferencing rules (`g_object_unref`, `g_variant_unref`, etc.).
