---
name: vergebar-popover-builder
description: >-
  Build and attach GTK4 interactive popovers to vergebar modules following
  proper GTK widget lifecycles, memory management, and English UI labels.
---

# Vergebar Popover Builder Skill

Use this procedure when adding an interactive card or menu popover (`GtkPopover`) to a Vergebar module.

## 1. Requirements
1. **English Language**: All visible UI strings (titles, buttons, status items) must be in English.
2. **Current API Usage**:
   - Use `mem.printSentinel` for null-terminated C-strings.
   - Do not use deprecated GTK4 or std formatting methods.
3. **Memory & Lifecycle Safety**:
   - Store `popover: ?*gtk.GtkWidget = null` on the module struct.
   - In `deinit()`: Unparent active popover with `gtk.gtk_widget_unparent(pop)` and free context allocations.
   - Always clear old callback contexts before creating new ones on toggle.

## 2. Standard Popover Implementation Pattern
```zig
const ItemActionContext = struct {
    id: [:0]const u8,
    allocator: Allocator,
    mod: *MyModule,
};

// Hooking click in module create:
this.base.custom_click_handler = &onClick;
this.base.custom_click_data = this;

fn onClick(user_data: ?*anyopaque, btn_num: c_uint) bool {
    _ = btn_num;
    const this: *MyModule = @ptrCast(@alignCast(user_data orelse return false));
    this.togglePopover();
    return true;
}

pub fn togglePopover(this: *MyModule) void {
    if (this.popover) |pop| {
        if (gtk.gtk_widget_get_visible(pop) != 0) {
            gtk.gtk_popover_popdown(@ptrCast(pop));
            return;
        } else {
            gtk.gtk_widget_unparent(pop);
            this.popover = null;
        }
    }

    // Clean up previous callback contexts
    for (this.action_contexts.items) |ctx| {
        this.allocator.free(ctx.id);
        this.allocator.destroy(ctx);
    }
    this.action_contexts.clearRetainingCapacity();

    const parent_btn = this.base.button orelse return;
    const pop = gtk.gtk_popover_new() orelse return;
    gtk.gtk_widget_set_parent(pop, parent_btn);
    this.popover = pop;

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 6);
    if (box) |b| {
        gtk.gtk_widget_add_css_class(b, "module-popover");

        const header = gtk.gtk_label_new("Popover Title");
        if (header) |h| {
            gtk.gtk_widget_add_css_class(h, "title");
            gtk.gtk_box_append(@ptrCast(b), h);
        }

        const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        if (sep) |s| gtk.gtk_box_append(@ptrCast(b), s);

        // Content / List Items / Buttons
        const btn = gtk.gtk_button_new_with_label("Action Button");
        if (btn) |btn_w| {
            _ = gtk.g_signal_connect_data(btn_w, "clicked", @ptrCast(&onActionClicked), this, null, 0);
            gtk.gtk_box_append(@ptrCast(b), btn_w);
        }

        gtk.gtk_popover_set_child(@ptrCast(pop), b);
    }

    gtk.gtk_popover_popup(@ptrCast(pop));
}

fn onActionClicked(button: ?*gtk.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const this: *MyModule = @ptrCast(@alignCast(user_data orelse return));
    // Perform action
    if (this.popover) |pop| gtk.gtk_popover_popdown(@ptrCast(pop));
}
```
