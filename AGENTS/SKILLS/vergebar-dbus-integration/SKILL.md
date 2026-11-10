---
name: vergebar-dbus-integration
description: >-
  Integrate Linux system and session D-Bus services into vergebar modules
  using the project's native gdbus bindings with zero subprocess overhead.
---

# Vergebar D-Bus Integration Skill

Use this procedure when interacting with system or session D-Bus interfaces (e.g. systemd, logind, UPower, BlueZ, MPRIS, WirePlumber).

## 1. Core Principles
1. **Zero Subprocess Overhead**: Never run `busctl` or external shell commands in loops or callbacks. Use `bindings.gdbus`.
2. **Connection Management**:
   - Acquire connections via `gdbus.getBus(.system)` or `gdbus.getBus(.session)`.
   - Store the connection pointer on the module struct if queried repeatedly.
   - In `deinit()`: Release acquired connection with `gdbus.g_object_unref(conn)`.
3. **Memory Safety with GVariant**:
   - Always free method return values with `defer gdbus.g_variant_unref(res);`.
   - Always free child variants fetched with `g_variant_get_child_value` or `g_variant_get_variant`.
   - Free iterators with `g_variant_iter_free(iter);`.

## 2. Common Patterns

### Fire-and-Forget Method Call
```zig
const bus = this.system_bus orelse return;
if (gdbus.g_variant_new_parsed("('sample_param', true)")) |params| {
    gdbus.callMethodFireAndForget(
        bus,
        "org.freedesktop.SampleService",
        "/org/freedesktop/SamplePath",
        "org.freedesktop.SampleInterface",
        "SampleMethod",
        params,
    );
}
```

### Synchronous Method Call & Value Extraction
```zig
const bus = this.session_bus orelse return;
const params = gdbus.g_variant_new_parsed("(['filter'],)") orelse return;
const res = gdbus.callMethodSync(
    bus,
    "org.freedesktop.SampleService",
    "/org/freedesktop/SamplePath",
    "org.freedesktop.SampleInterface",
    "ListItems",
    params,
);
if (res) |r| {
    defer gdbus.g_variant_unref(r);
    const outer = gdbus.g_variant_get_child_value(r, 0);
    if (outer) |out| {
        defer gdbus.g_variant_unref(out);
        const iter = gdbus.g_variant_iter_new(out);
        if (iter) |it| {
            defer gdbus.g_variant_iter_free(it);
            while (gdbus.g_variant_iter_next_value(it)) |entry| {
                defer gdbus.g_variant_unref(entry);
                // process entry
            }
        }
    }
}
```
