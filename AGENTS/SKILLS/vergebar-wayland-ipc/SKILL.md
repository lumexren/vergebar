---
name: vergebar-wayland-ipc
description: >-
  Connect to Wayland compositors (Hyprland, Sway, Niri) via Unix domain sockets
  for zero-latency, event-driven status updates and IPC dispatching.
---

# Vergebar Wayland IPC Skill

Use this procedure when connecting to Wayland compositor sockets or dispatching compositor actions.

## 1. Principles
1. **Event-Driven Over Polling**: Use non-blocking Unix domain socket listeners on background threads or GLib FD sources instead of polling loops.
2. **Zero Subprocesses**: Query or dispatch through compositor IPC sockets (`$XDG_RUNTIME_DIR/...`) rather than executing CLI tools (`hyprctl`, `swaymsg`, `niri msg`).
3. **Compositor Detection**:
   - Hyprland: `env.get("HYPRLAND_INSTANCE_SIGNATURE")`
   - Sway: `env.get("SWAYSOCK")`
   - Niri: `env.get("NIRI_SOCKET")`

## 2. Querying Compositor Sockets
Use `src/utils/ipc.zig` ergonomic helpers:
```zig
const ipc = @import("utils").ipc;

// Hyprland socket dispatch/query
if (ipc.queryHyprlandSocket(allocator, "j/activewindow")) |response| {
    defer allocator.free(response);
    // Parse JSON response
}

// Sway IPC dispatch/query (type 0 = command, type 1 = get_workspaces)
if (ipc.querySwaySocket(allocator, 1, "")) |response| {
    defer allocator.free(response);
    // Parse JSON response
}
```

## 3. Asynchronous Socket Listening Pattern
For modules that react to compositor events (e.g. `workspaces`, `window`, `taskbar`):
- Open non-blocking socket stream via `posix.connect`.
- Read events incrementally into stack buffer.
- When an event occurs, notify GTK main thread using `gtk.g_idle_add`.
- Clean up threads and close file descriptors on `deinit()`.
