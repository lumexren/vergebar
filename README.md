![vergebar](https://img.shields.io/badge/vergebar-gray?style=for-the-badge&logo=zig&logoColor=orange)
![License](https://img.shields.io/badge/License-GPL--3.0-orange?style=for-the-badge)
![Stars](https://img.shields.io/github/stars/lumexren/vergebar?style=for-the-badge&color=DAA520)
![Issues](https://img.shields.io/github/issues/lumexren/vergebar?style=for-the-badge)
![Last Commit](https://img.shields.io/github/last-commit/lumexren/vergebar?style=for-the-badge&color=F7A41D)

A high-performance Wayland status bar written in Zig, built on GTK4 and gtk4-layer-shell with native Waybar configuration and style support.

## Dependencies

- **Zig**: `>= 0.18.0-dev`
- **GTK4** (`gtk4`)
- **gtk4-layer-shell** (`gtk4-layer-shell`)

```bash
# Arch Linux
sudo pacman -S gtk4 gtk4-layer-shell
```

## Build & Install

```bash
git clone https://github.com/lumexren/vergebar.git
cd vergebar
zig build -Doptimize=fast
```

The compiled binary will be placed at `zig-out/bin/vergebar`.

## Usage

```bash
# Automatic config discovery (~/.config/vergebar/ or ~/.config/waybar/)
./zig-out/bin/vergebar

# Custom config and style
./zig-out/bin/vergebar -c path/to/config.jsonc -s path/to/style.css
```

## Acknowledgments

- **Zig Team** - For creating an amazing systems programming language
- **Waybar Contributors** - For the inspiration and format standards
- **Community** - For feedback, bug reports, and contributions

---

<div align="center">

**Built with ❤️ by lumexren**

*Star ⭐ this repo if you find it useful!*

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](./LICENSE) for details.

</div>
