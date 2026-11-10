---
name: vergebar-audit-rules
description: >-
  Audit vergebar code changes for conventions, deprecated APIs, style rules,
  redundant comments, and build integrity.
---

# Vergebar Audit & Quality Checklist Skill

Use this checklist before finalizing any changes, proposing commits, or pushing code.

## 1. Deprecated Functions Check
- Never use deprecated Zig std or GTK/GIO functions.
- Formatting null-terminated strings for C-APIs:
  - ✅ Use `std.mem.printSentinel(&buf, "...", .{args}, 0)`.
  - ❌ Do NOT use deprecated `bufPrintZ` or custom obsolete wrappers.
- Do not call deprecated GTK4 or GLib APIs.

## 2. Code Cleanliness & Comment Integrity
- **No Redundant Comments**: Do not add comments describing the obvious (e.g. `// Event-driven...`, `// 1. Try...`, `// Clean up...`).
- Preserve existing docstrings and license headers without adding conversational explanations.
- All visible UI texts (popovers, buttons, tooltips) must be in English.

## 3. Idiomatic Zig Conventions
- Result location type inference: Use `.init(...)`, `.{ ... }`, `.empty` when target type is known.
- Receiver naming: Use `this: *<Module>` for struct methods.
- Parameter order: `(io: Io, allocator: Allocator, ...)` consistently.

## 4. Verification Workflow
Execute the following commands in order and ensure all pass cleanly:
```bash
# 1. Format verification
zig fmt --check src/ AGENTS/

# 2. Test suite verification
zig build test --summary all

# 3. Release build verification
zig build -Doptimize=ReleaseFast --summary all
```
