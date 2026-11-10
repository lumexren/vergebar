---
name: vergebar-release-pkg
description: >-
  Maintain distribution packages (PKGBUILD), manual pages (roff/man), shell completions,
  and release artifacts across updates.
---

# Vergebar Release & Packaging Skill

Use this procedure when updating version numbers, documentation, packaging files, or release configurations.

## 1. Release Files Map
- **PKGBUILD**: `contrib/PKGBUILD` (Arch Linux package recipe)
- **Shell Completions**:
  - Bash: `contrib/completions/vergebar.bash`
  - Zsh: `contrib/completions/vergebar.zsh`
  - Fish: `contrib/completions/vergebar.fish`
- **Man Pages**:
  - Command: `doc/vergebar.1`
  - Configuration format: `doc/vergebar.5`
- **Systemd User Service**: `resources/vergebar.service`

## 2. Release Checklist
1. **Module Parity in Docs**:
   - Ensure all active modules in `src/modules/root.zig` are documented in `doc/vergebar.5` under module options.
   - Verify sample blocks in `examples/config.jsonc`.
2. **Flag Parity in Shell Completions**:
   - Ensure new CLI flags added to `src/root.zig` are added to bash, zsh, and fish completion scripts.
3. **PKGBUILD Validation**:
   - Ensure `pkgver` matches current release version.
   - Verify build and package commands match current Zig compiler expectations (`zig build -Doptimize=ReleaseFast`).
