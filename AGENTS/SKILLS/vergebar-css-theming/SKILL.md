---
name: vergebar-css-theming
description: >-
  Manage and structure GTK4 CSS classes, dynamic state transitions, popover styling,
  and bar aesthetics for vergebar.
---

# Vergebar CSS Theming Skill

Use this procedure when styling bar widgets, handling state classes, or designing popover CSS rules.

## 1. Class Hierarchy & State Classes
Modules inherit from `BaseModule` and should apply standardized CSS classes:
- **Base Widget**: `.vergebar-module`, `#<module-name>`
- **Active State**: `.active`
- **Connection States**: `.connected`, `.disconnected`, `.linked`
- **Threshold States**: `.warning`, `.critical` (applied automatically via `this.base.setClasses(is_warning, is_critical)`)
- **Status States**: `.failed`, `.ok`, `.muted`

## 2. Dynamic Class Management in Zig
```zig
// Adding/removing classes safely
this.base.addCssClass("connected");
this.base.removeCssClass("disconnected");

// Popover container styling
const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 6);
if (box) |b| {
    gtk.gtk_widget_add_css_class(b, "<module>-popover");
}

// Subtitles and destructive actions
gtk.gtk_widget_add_css_class(label_widget, "subtitle");
gtk.gtk_widget_add_css_class(danger_button, "destructive-action");
```

## 3. Style Sheet Conventions (`examples/style.css`)
- Use clean, modern translucent layers (`rgba(...)`).
- Maintain consistent border-radius (e.g. `8px` or `12px` for popovers).
- Provide smooth transition states (`transition: all 0.2s ease;`).
- Style progress bars cleanly:
  ```css
  .module-popover progressbar trough {
      min-height: 6px;
      border-radius: 3px;
      background: rgba(255, 255, 255, 0.1);
  }
  .module-popover progressbar progress {
      border-radius: 3px;
      background: #7aa2f7;
  }
  ```
