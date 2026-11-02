// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of vergebar.
//
// Copyright (c) 2026 lumexren
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://gnu.org/licenses>.

pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;
pub const GCallback = ?*const fn () callconv(.c) void;
pub const GClosureNotify = ?*const fn (data: gpointer, closure: ?*anyopaque) callconv(.c) void;
pub const GSourceFunc = ?*const fn (user_data: gpointer) callconv(.c) gboolean;

pub const GtkWidget = anyopaque;
pub const GtkWindow = anyopaque;
pub const GtkBox = anyopaque;
pub const GtkCenterBox = anyopaque;
pub const GtkLabel = anyopaque;
pub const GtkButton = anyopaque;
pub const GtkCssProvider = anyopaque;
pub const GtkStyleProvider = anyopaque;
pub const GtkEventController = anyopaque;
pub const GtkGestureClick = anyopaque;
pub const GtkGestureSingle = anyopaque;

pub const GdkDisplay = anyopaque;
pub const GdkMonitor = anyopaque;
pub const GdkSurface = anyopaque;

pub const GListModel = anyopaque;
pub const GMainLoop = anyopaque;
pub const GMainContext = anyopaque;

pub const GTK_ORIENTATION_HORIZONTAL: c_uint = 0;
pub const GTK_ORIENTATION_VERTICAL: c_uint = 1;

pub const GTK_STYLE_PROVIDER_PRIORITY_FALLBACK: c_uint = 1;
pub const GTK_STYLE_PROVIDER_PRIORITY_THEME: c_uint = 200;
pub const GTK_STYLE_PROVIDER_PRIORITY_SETTINGS: c_uint = 400;
pub const GTK_STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;
pub const GTK_STYLE_PROVIDER_PRIORITY_USER: c_uint = 800;

pub const GTK_LAYER_SHELL_LAYER_BACKGROUND: c_uint = 0;
pub const GTK_LAYER_SHELL_LAYER_BOTTOM: c_uint = 1;
pub const GTK_LAYER_SHELL_LAYER_TOP: c_uint = 2;
pub const GTK_LAYER_SHELL_LAYER_OVERLAY: c_uint = 3;

pub const GTK_LAYER_SHELL_EDGE_LEFT: c_uint = 0;
pub const GTK_LAYER_SHELL_EDGE_RIGHT: c_uint = 1;
pub const GTK_LAYER_SHELL_EDGE_TOP: c_uint = 2;
pub const GTK_LAYER_SHELL_EDGE_BOTTOM: c_uint = 3;
pub const GTK_LAYER_SHELL_EDGE_ENTRY_NUMBER: c_uint = 4;

pub const GTK_LAYER_SHELL_KEYBOARD_MODE_NONE: c_uint = 0;
pub const GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE: c_uint = 1;
pub const GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND: c_uint = 2;

pub extern "c" fn gtk_init() void;
pub extern "c" fn gtk_window_new() ?*GtkWidget;
pub extern "c" fn gtk_window_set_title(window: ?*GtkWindow, title: ?[*:0]const u8) void;
pub extern "c" fn gtk_window_set_default_size(window: ?*GtkWindow, width: c_int, height: c_int) void;
pub extern "c" fn gtk_window_set_child(window: ?*GtkWindow, child: ?*GtkWidget) void;
pub extern "c" fn gtk_window_present(window: ?*GtkWindow) void;
pub extern "c" fn gtk_window_destroy(window: ?*GtkWindow) void;

pub extern "c" fn gtk_widget_set_visible(widget: ?*GtkWidget, visible: gboolean) void;
pub extern "c" fn gtk_widget_set_name(widget: ?*GtkWidget, name: ?[*:0]const u8) void;
pub extern "c" fn gtk_widget_add_css_class(widget: ?*GtkWidget, css_class: ?[*:0]const u8) void;
pub extern "c" fn gtk_widget_remove_css_class(widget: ?*GtkWidget, css_class: ?[*:0]const u8) void;
pub extern "c" fn gtk_widget_has_css_class(widget: ?*GtkWidget, css_class: ?[*:0]const u8) gboolean;
pub extern "c" fn gtk_widget_set_tooltip_text(widget: ?*GtkWidget, text: ?[*:0]const u8) void;
pub extern "c" fn gtk_widget_set_tooltip_markup(widget: ?*GtkWidget, markup: ?[*:0]const u8) void;
pub extern "c" fn gtk_widget_add_controller(widget: ?*GtkWidget, controller: ?*GtkEventController) void;

pub extern "c" fn gtk_box_new(orientation: c_uint, spacing: c_int) ?*GtkWidget;
pub extern "c" fn gtk_box_append(box: ?*GtkBox, child: ?*GtkWidget) void;
pub extern "c" fn gtk_box_prepend(box: ?*GtkBox, child: ?*GtkWidget) void;
pub extern "c" fn gtk_box_remove(box: ?*GtkBox, child: ?*GtkWidget) void;
pub extern "c" fn gtk_box_set_spacing(box: ?*GtkBox, spacing: c_int) void;

pub extern "c" fn gtk_center_box_new() ?*GtkWidget;
pub extern "c" fn gtk_center_box_set_start_widget(self: ?*GtkCenterBox, child: ?*GtkWidget) void;
pub extern "c" fn gtk_center_box_set_center_widget(self: ?*GtkCenterBox, child: ?*GtkWidget) void;
pub extern "c" fn gtk_center_box_set_end_widget(self: ?*GtkCenterBox, child: ?*GtkWidget) void;

pub extern "c" fn gtk_label_new(str: ?[*:0]const u8) ?*GtkWidget;
pub extern "c" fn gtk_label_set_text(label: ?*GtkLabel, str: ?[*:0]const u8) void;
pub extern "c" fn gtk_label_set_markup(label: ?*GtkLabel, str: ?[*:0]const u8) void;
pub extern "c" fn gtk_label_set_use_markup(label: ?*GtkLabel, setting: gboolean) void;
pub extern "c" fn gtk_label_get_text(label: ?*GtkLabel) ?[*:0]const u8;

pub extern "c" fn gtk_button_new() ?*GtkWidget;
pub extern "c" fn gtk_button_new_with_label(label: ?[*:0]const u8) ?*GtkWidget;
pub extern "c" fn gtk_button_set_child(button: ?*GtkButton, child: ?*GtkWidget) void;
pub extern "c" fn gtk_button_set_has_frame(button: ?*GtkButton, has_frame: gboolean) void;

pub extern "c" fn gtk_gesture_click_new() ?*GtkGestureClick;
pub extern "c" fn gtk_gesture_single_set_button(gesture: ?*GtkGestureSingle, button: c_uint) void;
pub extern "c" fn gtk_gesture_single_get_current_button(gesture: ?*GtkGestureSingle) c_uint;

pub extern "c" fn gtk_css_provider_new() ?*GtkCssProvider;
pub extern "c" fn gtk_css_provider_load_from_path(provider: ?*GtkCssProvider, path: ?[*:0]const u8) void;
pub extern "c" fn gtk_css_provider_load_from_string(provider: ?*GtkCssProvider, string: ?[*:0]const u8) void;
pub extern "c" fn gtk_style_context_add_provider_for_display(display: ?*GdkDisplay, provider: ?*GtkStyleProvider, priority: c_uint) void;

pub extern "c" fn gdk_display_get_default() ?*GdkDisplay;
pub extern "c" fn gdk_display_get_monitors(display: ?*GdkDisplay) ?*GListModel;
pub extern "c" fn g_list_model_get_n_items(list: ?*GListModel) c_uint;
pub extern "c" fn g_list_model_get_item(list: ?*GListModel, position: c_uint) ?*anyopaque;
pub extern "c" fn gdk_monitor_get_connector(monitor: ?*GdkMonitor) ?[*:0]const u8;
pub extern "c" fn gdk_monitor_get_description(monitor: ?*GdkMonitor) ?[*:0]const u8;

pub extern "c" fn gtk_layer_init_for_window(window: ?*GtkWindow) void;
pub extern "c" fn gtk_layer_is_layer_window(window: ?*GtkWindow) gboolean;
pub extern "c" fn gtk_layer_set_namespace(window: ?*GtkWindow, name_space: ?[*:0]const u8) void;
pub extern "c" fn gtk_layer_get_namespace(window: ?*GtkWindow) ?[*:0]const u8;
pub extern "c" fn gtk_layer_set_layer(window: ?*GtkWindow, layer: c_uint) void;
pub extern "c" fn gtk_layer_get_layer(window: ?*GtkWindow) c_uint;
pub extern "c" fn gtk_layer_set_monitor(window: ?*GtkWindow, monitor: ?*GdkMonitor) void;
pub extern "c" fn gtk_layer_get_monitor(window: ?*GtkWindow) ?*GdkMonitor;
pub extern "c" fn gtk_layer_set_anchor(window: ?*GtkWindow, edge: c_uint, anchor: gboolean) void;
pub extern "c" fn gtk_layer_get_anchor(window: ?*GtkWindow, edge: c_uint) gboolean;
pub extern "c" fn gtk_layer_set_margin(window: ?*GtkWindow, edge: c_uint, margin_size: c_int) void;
pub extern "c" fn gtk_layer_get_margin(window: ?*GtkWindow, edge: c_uint) c_int;
pub extern "c" fn gtk_layer_set_exclusive_zone(window: ?*GtkWindow, exclusive_zone: c_int) void;
pub extern "c" fn gtk_layer_get_exclusive_zone(window: ?*GtkWindow) c_int;
pub extern "c" fn gtk_layer_auto_exclusive_zone_enable(window: ?*GtkWindow) void;
pub extern "c" fn gtk_layer_auto_exclusive_zone_is_enabled(window: ?*GtkWindow) gboolean;
pub extern "c" fn gtk_layer_set_keyboard_mode(window: ?*GtkWindow, mode: c_uint) void;
pub extern "c" fn gtk_layer_get_keyboard_mode(window: ?*GtkWindow) c_uint;

pub extern "c" fn g_main_loop_new(context: ?*GMainContext, is_running: gboolean) ?*GMainLoop;
pub extern "c" fn g_main_loop_run(loop: ?*GMainLoop) void;
pub extern "c" fn g_main_loop_quit(loop: ?*GMainLoop) void;
pub extern "c" fn g_timeout_add(interval_ms: c_uint, function: GSourceFunc, data: gpointer) c_uint;
pub extern "c" fn g_timeout_add_seconds(interval_sec: c_uint, function: GSourceFunc, data: gpointer) c_uint;
pub extern "c" fn g_idle_add(function: GSourceFunc, data: gpointer) c_uint;
pub extern "c" fn g_source_remove(tag: c_uint) gboolean;
pub extern "c" fn g_signal_connect_data(
    instance: gpointer,
    detailed_signal: [*:0]const u8,
    c_handler: GCallback,
    data: gpointer,
    destroy_data: GClosureNotify,
    connect_flags: c_uint,
) c_ulong;
pub extern "c" fn g_object_unref(object: gpointer) void;
pub extern "c" fn g_spawn_command_line_async(command_line: [*:0]const u8, err: ?*?*anyopaque) gboolean;
pub extern "c" fn g_get_real_time() i64;
pub extern "c" fn g_getenv(variable: [*:0]const u8) ?[*:0]const u8;
pub extern "c" fn g_setenv(variable: [*:0]const u8, value: [*:0]const u8, overwrite: gboolean) gboolean;

pub const GtkEventControllerScroll = anyopaque;
pub const GTK_EVENT_CONTROLLER_SCROLL_VERTICAL: c_uint = 1;
pub const GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES: c_uint = 3;
pub extern "c" fn gtk_event_controller_scroll_new(flags: c_uint) ?*GtkEventControllerScroll;

pub const GtkImage = anyopaque;
pub extern "c" fn gtk_image_new() ?*GtkWidget;
pub extern "c" fn gtk_image_new_from_icon_name(icon_name: ?[*:0]const u8) ?*GtkWidget;
pub extern "c" fn gtk_image_set_from_icon_name(image: ?*GtkImage, icon_name: ?[*:0]const u8) void;
pub extern "c" fn gtk_image_set_pixel_size(image: ?*GtkImage, pixel_size: c_int) void;

pub const GDBusConnection = anyopaque;
pub const GDBusProxy = anyopaque;
pub const GVariant = anyopaque;
pub const GVariantIter = anyopaque;

pub const GBusType = enum(c_int) {
    starter = -1,
    none = 0,
    system = 1,
    session = 2,
};

pub const GDBusSignalCallback = ?*const fn (
    connection: ?*GDBusConnection,
    sender_name: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    signal_name: ?[*:0]const u8,
    parameters: ?*GVariant,
    user_data: gpointer,
) callconv(.c) void;

pub extern "c" fn g_bus_get_sync(bus_type: c_int, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*GDBusConnection;
pub extern "c" fn g_dbus_connection_signal_subscribe(
    connection: ?*GDBusConnection,
    sender: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    member: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    arg0: ?[*:0]const u8,
    flags: c_uint,
    callback: GDBusSignalCallback,
    user_data: gpointer,
    user_data_free_func: ?*const fn (gpointer) callconv(.c) void,
) c_uint;
pub extern "c" fn g_dbus_connection_signal_unsubscribe(connection: ?*GDBusConnection, subscription_id: c_uint) void;
pub extern "c" fn g_dbus_connection_call_sync(
    connection: ?*GDBusConnection,
    bus_name: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    method_name: ?[*:0]const u8,
    parameters: ?*GVariant,
    reply_type: ?*anyopaque,
    flags: c_uint,
    timeout_msec: c_int,
    cancellable: ?*anyopaque,
    err: ?*?*anyopaque,
) ?*GVariant;

pub extern "c" fn g_dbus_proxy_new_sync(
    connection: ?*GDBusConnection,
    flags: c_uint,
    info: ?*anyopaque,
    name: ?[*:0]const u8,
    path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    cancellable: ?*anyopaque,
    err: ?*?*anyopaque,
) ?*GDBusProxy;
pub extern "c" fn g_dbus_proxy_get_cached_property(proxy: ?*GDBusProxy, property_name: [*:0]const u8) ?*GVariant;
pub extern "c" fn g_dbus_proxy_call_sync(
    proxy: ?*GDBusProxy,
    method_name: [*:0]const u8,
    parameters: ?*GVariant,
    flags: c_uint,
    timeout_msec: c_int,
    cancellable: ?*anyopaque,
    err: ?*?*anyopaque,
) ?*GVariant;

pub extern "c" fn g_variant_unref(value: ?*GVariant) void;
pub extern "c" fn g_variant_get_child_value(value: ?*GVariant, index_: usize) ?*GVariant;
pub extern "c" fn g_variant_get_string(value: ?*GVariant, length: ?*usize) ?[*:0]const u8;
pub extern "c" fn g_variant_get_data(value: ?*GVariant) ?*anyopaque;
pub extern "c" fn g_variant_get_size(value: ?*GVariant) usize;
pub extern "c" fn g_variant_get_bytestring(value: ?*GVariant) ?[*:0]const u8;
pub extern "c" fn g_variant_get_byte(value: ?*GVariant) u8;
pub extern "c" fn g_variant_get_boolean(value: ?*GVariant) gboolean;
pub extern "c" fn g_variant_get_int32(value: ?*GVariant) i32;
pub extern "c" fn g_variant_get_uint32(value: ?*GVariant) u32;
pub extern "c" fn g_variant_get_double(value: ?*GVariant) f64;
pub extern "c" fn g_variant_iter_new(value: ?*GVariant) ?*GVariantIter;
pub extern "c" fn g_variant_iter_next_value(iter: ?*GVariantIter) ?*GVariant;
pub extern "c" fn g_variant_iter_free(iter: ?*GVariantIter) void;
pub extern "c" fn g_variant_new_string(string: [*:0]const u8) ?*GVariant;
pub extern "c" fn g_variant_new(format: [*:0]const u8, ...) ?*GVariant;
pub extern "c" fn g_variant_new_parsed(format: [*:0]const u8, ...) ?*GVariant;
pub extern "c" fn g_variant_lookup_value(dictionary: ?*GVariant, key: [*:0]const u8, expected_type: ?*anyopaque) ?*GVariant;
pub extern "c" fn g_variant_is_container(value: ?*GVariant) gboolean;
pub extern "c" fn g_variant_get_variant(value: ?*GVariant) ?*GVariant;
pub extern "c" fn g_variant_n_children(value: ?*GVariant) usize;
pub extern "c" fn g_free(mem: ?*anyopaque) void;

pub const GtkPopover = anyopaque;
pub extern "c" fn gtk_popover_new() ?*GtkWidget;
pub extern "c" fn gtk_popover_set_child(popover: ?*GtkPopover, child: ?*GtkWidget) void;
pub extern "c" fn gtk_popover_popup(popover: ?*GtkPopover) void;
pub extern "c" fn gtk_popover_popdown(popover: ?*GtkPopover) void;
pub extern "c" fn gtk_widget_set_parent(widget: ?*GtkWidget, parent: ?*GtkWidget) void;
pub extern "c" fn gtk_widget_unparent(widget: ?*GtkWidget) void;
pub extern "c" fn gtk_widget_set_sensitive(widget: ?*GtkWidget, sensitive: gboolean) void;
pub extern "c" fn gtk_separator_new(orientation: c_uint) ?*GtkWidget;

pub const GFile = anyopaque;
pub const GFileMonitor = anyopaque;
pub extern "c" fn g_file_new_for_path(path: [*:0]const u8) ?*GFile;
pub extern "c" fn g_file_monitor_file(
    file: ?*GFile,
    flags: c_uint,
    cancellable: ?*anyopaque,
    err: ?*?*anyopaque,
) ?*GFileMonitor;

pub extern "c" fn g_dbus_proxy_get_name_owner(proxy: ?*GDBusProxy) ?[*:0]const u8;
pub extern "c" fn g_error_free(err: ?*anyopaque) void;

pub const GtkIconTheme = anyopaque;
pub extern "c" fn gtk_icon_theme_get_for_display(display: ?*GdkDisplay) ?*GtkIconTheme;
pub extern "c" fn gtk_icon_theme_add_search_path(icon_theme: ?*GtkIconTheme, path: [*:0]const u8) void;

pub extern "c" fn gtk_image_set_from_paintable(image: ?*GtkImage, paintable: ?*anyopaque) void;
pub extern "c" fn gdk_memory_texture_new(width: c_int, height: c_int, format: c_uint, bytes: ?*anyopaque, stride: usize) ?*anyopaque;
pub extern "c" fn g_bytes_new(data: ?*const anyopaque, size: usize) ?*anyopaque;
pub extern "c" fn g_bytes_unref(bytes: ?*anyopaque) void;

pub extern "c" fn g_bus_own_name_on_connection(
    connection: ?*GDBusConnection,
    name: [*:0]const u8,
    flags: c_uint,
    name_acquired_handler: ?*const fn (?*GDBusConnection, [*:0]const u8, gpointer) callconv(.c) void,
    name_lost_handler: ?*const fn (?*GDBusConnection, [*:0]const u8, gpointer) callconv(.c) void,
    user_data: gpointer,
    user_data_free_func: ?*const fn (gpointer) callconv(.c) void,
) c_uint;
pub extern "c" fn g_bus_unown_name(owner_id: c_uint) void;
pub extern "c" fn g_dbus_node_info_new_for_xml(xml: [*:0]const u8, err: ?*?*anyopaque) ?*anyopaque;
pub extern "c" fn g_dbus_method_invocation_return_value(invocation: ?*anyopaque, parameters: ?*GVariant) void;
pub extern "c" fn g_variant_is_of_type(value: ?*GVariant, type_string: [*:0]const u8) gboolean;
pub extern "c" fn g_variant_get_type_string(value: ?*GVariant) [*:0]const u8;

pub const GtkRevealer = anyopaque;
pub const GTK_REVEALER_TRANSITION_TYPE_NONE: c_uint = 0;
pub const GTK_REVEALER_TRANSITION_TYPE_CROSSFADE: c_uint = 1;
pub const GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT: c_uint = 2;
pub const GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT: c_uint = 3;
pub const GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP: c_uint = 4;
pub const GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN: c_uint = 5;

pub extern "c" fn gtk_revealer_new() ?*GtkWidget;
pub extern "c" fn gtk_revealer_set_reveal_child(revealer: ?*GtkRevealer, reveal_child: gboolean) void;
pub extern "c" fn gtk_revealer_get_reveal_child(revealer: ?*GtkRevealer) gboolean;
pub extern "c" fn gtk_revealer_set_transition_type(revealer: ?*GtkRevealer, transition: c_uint) void;
pub extern "c" fn gtk_revealer_set_transition_duration(revealer: ?*GtkRevealer, duration: c_uint) void;
pub extern "c" fn gtk_revealer_set_child(revealer: ?*GtkRevealer, child: ?*GtkWidget) void;

pub const GtkEventControllerMotion = anyopaque;
pub extern "c" fn gtk_event_controller_motion_new() ?*GtkEventControllerMotion;

pub const GtkScale = anyopaque;
pub const GtkRange = anyopaque;
pub extern "c" fn gtk_scale_new_with_range(orientation: c_uint, min: f64, max: f64, step: f64) ?*GtkWidget;
pub extern "c" fn gtk_range_set_value(range: ?*GtkRange, value: f64) void;
pub extern "c" fn gtk_range_get_value(range: ?*GtkRange) f64;
pub extern "c" fn gtk_range_set_range(range: ?*GtkRange, min: f64, max: f64) void;
pub extern "c" fn gtk_scale_set_draw_value(scale: ?*GtkScale, draw_value: gboolean) void;
pub extern "c" fn gtk_scale_set_has_origin(scale: ?*GtkScale, has_origin: gboolean) void;

pub extern "c" fn gtk_image_new_from_file(filename: ?[*:0]const u8) ?*GtkWidget;
pub extern "c" fn gtk_image_set_from_file(image: ?*GtkImage, filename: ?[*:0]const u8) void;

pub const GTK_ALIGN_FILL: c_uint = 0;
pub const GTK_ALIGN_START: c_uint = 1;
pub const GTK_ALIGN_END: c_uint = 2;
pub const GTK_ALIGN_CENTER: c_uint = 3;
pub const GTK_ALIGN_BASELINE: c_uint = 4;

pub extern "c" fn gtk_widget_set_size_request(widget: ?*GtkWidget, width: c_int, height: c_int) void;
pub extern "c" fn gtk_widget_set_hexpand(widget: ?*GtkWidget, expand: gboolean) void;
pub extern "c" fn gtk_widget_set_vexpand(widget: ?*GtkWidget, expand: gboolean) void;
pub extern "c" fn gtk_widget_set_halign(widget: ?*GtkWidget, alignment: c_uint) void;
pub extern "c" fn gtk_widget_set_valign(widget: ?*GtkWidget, alignment: c_uint) void;
pub extern "c" fn gtk_widget_get_visible(widget: ?*GtkWidget) gboolean;

pub const graphene_point_t = extern struct {
    x: f32,
    y: f32,
};

pub extern "c" fn gtk_widget_get_root(widget: ?*GtkWidget) ?*anyopaque;
pub extern "c" fn gtk_widget_compute_point(widget: ?*GtkWidget, target: ?*anyopaque, point: *const graphene_point_t, out_point: *graphene_point_t) gboolean;

pub const GDBusInterfaceVTable = extern struct {
    method_call: ?*const fn (
        connection: ?*GDBusConnection,
        sender: [*:0]const u8,
        object_path: [*:0]const u8,
        interface_name: [*:0]const u8,
        method_name: [*:0]const u8,
        parameters: ?*GVariant,
        invocation: ?*anyopaque,
        user_data: gpointer,
    ) callconv(.c) void,
    get_property: ?*const fn (
        connection: ?*GDBusConnection,
        sender: [*:0]const u8,
        object_path: [*:0]const u8,
        interface_name: [*:0]const u8,
        property_name: [*:0]const u8,
        err: ?*?*anyopaque,
        user_data: gpointer,
    ) callconv(.c) ?*GVariant,
    set_property: ?*const fn (
        connection: ?*GDBusConnection,
        sender: [*:0]const u8,
        object_path: [*:0]const u8,
        interface_name: [*:0]const u8,
        property_name: [*:0]const u8,
        value: ?*GVariant,
        err: ?*?*anyopaque,
        user_data: gpointer,
    ) callconv(.c) gboolean,
    padding: [8]gpointer = [_]gpointer{ null, null, null, null, null, null, null, null },
};

pub extern "c" fn g_dbus_connection_register_object(
    connection: ?*GDBusConnection,
    object_path: [*:0]const u8,
    interface_info: ?*anyopaque,
    vtable: ?*const GDBusInterfaceVTable,
    user_data: gpointer,
    user_data_free_func: ?*const fn (gpointer) callconv(.c) void,
    err: ?*?*anyopaque,
) c_uint;

pub extern "c" fn g_dbus_connection_unregister_object(
    connection: ?*GDBusConnection,
    registration_id: c_uint,
) gboolean;

pub extern "c" fn g_dbus_connection_emit_signal(
    connection: ?*GDBusConnection,
    destination_bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    signal_name: [*:0]const u8,
    parameters: ?*GVariant,
    err: ?*?*anyopaque,
) gboolean;

pub extern "c" fn g_bus_watch_name_on_connection(
    connection: ?*GDBusConnection,
    name: [*:0]const u8,
    flags: c_uint,
    name_appeared_handler: ?*const fn (?*GDBusConnection, [*:0]const u8, [*:0]const u8, gpointer) callconv(.c) void,
    name_vanished_handler: ?*const fn (?*GDBusConnection, [*:0]const u8, gpointer) callconv(.c) void,
    user_data: gpointer,
    user_data_free_func: ?*const fn (gpointer) callconv(.c) void,
) c_uint;

pub extern "c" fn g_bus_unwatch_name(watcher_id: c_uint) void;
pub extern "c" fn g_dbus_connection_get_unique_name(connection: ?*GDBusConnection) ?[*:0]const u8;
pub extern "c" fn g_dbus_method_invocation_get_sender(invocation: ?*anyopaque) ?[*:0]const u8;
pub extern "c" fn g_dbus_node_info_lookup_interface(info: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
pub extern "c" fn g_dbus_node_info_unref(info: ?*anyopaque) void;

pub extern "c" fn g_variant_new_boolean(value: gboolean) ?*GVariant;
pub extern "c" fn g_variant_new_int32(value: i32) ?*GVariant;
pub extern "c" fn g_variant_new_strv(strv: ?[*]const ?[*:0]const u8, length: isize) ?*GVariant;

pub const GDateTime = anyopaque;
pub extern "c" fn g_date_time_new_now_local() ?*GDateTime;
pub extern "c" fn g_date_time_format(datetime: ?*GDateTime, format: [*:0]const u8) ?[*:0]u8;
pub extern "c" fn g_date_time_unref(datetime: ?*GDateTime) void;

pub const GtkBuilder = anyopaque;
pub extern "c" fn gtk_builder_new() ?*GtkBuilder;
pub extern "c" fn gtk_builder_add_from_file(builder: ?*GtkBuilder, filename: [*:0]const u8, err: ?*?*anyopaque) c_uint;
pub extern "c" fn gtk_builder_add_from_string(builder: ?*GtkBuilder, buffer: [*:0]const u8, length: isize, err: ?*?*anyopaque) c_uint;
pub extern "c" fn gtk_builder_get_object(builder: ?*GtkBuilder, name: [*:0]const u8) ?*anyopaque;
pub extern "c" fn g_object_ref(object: ?*anyopaque) ?*anyopaque;
