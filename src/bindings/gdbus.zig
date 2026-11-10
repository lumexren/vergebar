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

const std = @import("std");
const mem = std.mem;

pub const GBusType = enum(c_int) {
    starter = -1,
    none = 0,
    system = 1,
    session = 2,
};

pub const GDBusCallFlags = struct {
    pub const NONE: c_int = 0;
    pub const NO_AUTO_START: c_int = 1;
    pub const ALLOW_INTERACTIVE_AUTHORIZATION: c_int = 2;
};

pub const GDBusProxyFlags = struct {
    pub const NONE: c_int = 0;
    pub const DO_NOT_LOAD_PROPERTIES: c_int = 1;
    pub const DO_NOT_CONNECT_SIGNALS: c_int = 2;
    pub const DO_NOT_AUTO_START: c_int = 4;
    pub const GET_INVALIDATED_PROPERTIES: c_int = 8;
    pub const DO_NOT_AUTO_START_AT_CONSTRUCTION: c_int = 16;
};

pub const GVariant = opaque {};
pub const GVariantIter = opaque {};
pub const GDBusConnection = opaque {};
pub const GDBusProxy = opaque {};

pub const GError = extern struct {
    domain: u32,
    code: c_int,
    message: [*:0]const u8,
};

// Raw C Externs from libgio-2.0 and libglib-2.0
pub extern "c" fn g_bus_get_sync(bus_type: GBusType, cancellable: ?*anyopaque, err: ?*?*GError) ?*GDBusConnection;
pub extern "c" fn g_dbus_connection_call_sync(
    connection: *GDBusConnection,
    bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    parameters: ?*GVariant,
    reply_type: ?*const anyopaque,
    flags: c_int,
    timeout_msec: c_int,
    cancellable: ?*anyopaque,
    err: ?*?*GError,
) ?*GVariant;
pub extern "c" fn g_dbus_connection_call(
    connection: *GDBusConnection,
    bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    parameters: ?*GVariant,
    reply_type: ?*const anyopaque,
    flags: c_int,
    timeout_msec: c_int,
    cancellable: ?*anyopaque,
    callback: ?*const anyopaque,
    user_data: ?*anyopaque,
) void;

pub extern "c" fn g_dbus_proxy_new_for_bus_sync(
    bus_type: GBusType,
    flags: c_int,
    info: ?*anyopaque,
    name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    cancellable: ?*anyopaque,
    err: ?*?*GError,
) ?*GDBusProxy;

pub extern "c" fn g_dbus_proxy_call_sync(
    proxy: *GDBusProxy,
    method_name: [*:0]const u8,
    parameters: ?*GVariant,
    flags: c_int,
    timeout_msec: c_int,
    cancellable: ?*anyopaque,
    err: ?*?*GError,
) ?*GVariant;

pub extern "c" fn g_dbus_proxy_get_cached_property(proxy: *GDBusProxy, property_name: [*:0]const u8) ?*GVariant;

pub extern "c" fn g_object_unref(object: ?*anyopaque) void;
pub extern "c" fn g_error_free(err: *GError) void;
pub extern "c" fn g_free(mem_ptr: ?*anyopaque) void;

// GVariant functions
pub extern "c" fn g_variant_unref(value: ?*GVariant) void;
pub extern "c" fn g_variant_ref_sink(value: *GVariant) *GVariant;
pub extern "c" fn g_variant_new_string(string: [*:0]const u8) *GVariant;
pub extern "c" fn g_variant_new_parsed(format: [*:0]const u8, ...) ?*GVariant;
pub extern "c" fn g_variant_new_tuple(children: [*]const *GVariant, n_children: usize) *GVariant;
pub extern "c" fn g_variant_get_byte(value: *GVariant) u8;
pub extern "c" fn g_variant_get_string(value: *GVariant, length: ?*usize) [*:0]const u8;
pub extern "c" fn g_variant_get_boolean(value: *GVariant) c_int;
pub extern "c" fn g_variant_get_int32(value: *GVariant) i32;
pub extern "c" fn g_variant_get_uint32(value: *GVariant) u32;
pub extern "c" fn g_variant_get_int64(value: *GVariant) i64;
pub extern "c" fn g_variant_get_uint64(value: *GVariant) u64;
pub extern "c" fn g_variant_get_double(value: *GVariant) f64;
pub extern "c" fn g_variant_get_child_value(value: *GVariant, index: usize) ?*GVariant;
pub extern "c" fn g_variant_n_children(value: *GVariant) usize;
pub extern "c" fn g_variant_lookup_value(dictionary: *GVariant, given_key: [*:0]const u8, expected_type: ?*const anyopaque) ?*GVariant;
pub extern "c" fn g_variant_get_type_string(value: *GVariant) [*:0]const u8;
pub extern "c" fn g_variant_iter_new(value: *GVariant) ?*GVariantIter;
pub extern "c" fn g_variant_iter_free(iter: ?*GVariantIter) void;
pub extern "c" fn g_variant_iter_next_value(iter: *GVariantIter) ?*GVariant;
pub extern "c" fn g_variant_get_variant(value: *GVariant) *GVariant;

/// High-level ergonomic helpers for Zig
pub fn getBus(bus_type: GBusType) ?*GDBusConnection {
    var g_err: ?*GError = null;
    const conn = g_bus_get_sync(bus_type, null, &g_err);
    if (g_err) |e| {
        g_error_free(e);
        return null;
    }
    return conn;
}

pub fn callMethodSync(
    conn: *GDBusConnection,
    bus_name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    params: ?*GVariant,
) ?*GVariant {
    var g_err: ?*GError = null;
    const res = g_dbus_connection_call_sync(
        conn,
        bus_name,
        object_path,
        interface_name,
        method_name,
        params,
        null,
        GDBusCallFlags.NONE,
        2000,
        null,
        &g_err,
    );
    if (g_err) |e| {
        g_error_free(e);
        return null;
    }
    return res;
}

pub fn callMethodFireAndForget(
    conn: *GDBusConnection,
    bus_name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    params: ?*GVariant,
) void {
    g_dbus_connection_call(
        conn,
        bus_name,
        object_path,
        interface_name,
        method_name,
        params,
        null,
        GDBusCallFlags.NONE,
        1000,
        null,
        null,
        null,
    );
}

pub fn getPropertySync(
    conn: *GDBusConnection,
    bus_name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    property_name: [*:0]const u8,
) ?*GVariant {
    const p1 = g_variant_new_string(interface_name);
    const p2 = g_variant_new_string(property_name);
    const tuple_elems = [_]*GVariant{ p1, p2 };
    const params = g_variant_new_tuple(&tuple_elems, 2);

    const res = callMethodSync(
        conn,
        bus_name,
        object_path,
        "org.freedesktop.DBus.Properties",
        "Get",
        params,
    ) orelse return null;
    defer g_variant_unref(res);

    if (g_variant_n_children(res) < 1) return null;
    const boxed = g_variant_get_child_value(res, 0) orelse return null;
    defer g_variant_unref(boxed);
    return g_variant_get_variant(boxed);
}

pub fn getTypeStr(maybe_value: ?*GVariant) []const u8 {
    const value = maybe_value orelse return "";
    return mem.span(g_variant_get_type_string(value));
}

pub fn asString(maybe_value: ?*GVariant) ?[]const u8 {
    const value = maybe_value orelse return null;
    const t = getTypeStr(value);
    if (mem.eql(u8, t, "s") or mem.eql(u8, t, "o")) {
        var len: usize = 0;
        const ptr = g_variant_get_string(value, &len);
        return ptr[0..len];
    }
    return null;
}

pub fn asBoolean(maybe_value: ?*GVariant) ?bool {
    const value = maybe_value orelse return null;
    if (mem.eql(u8, getTypeStr(value), "b")) {
        return g_variant_get_boolean(value) != 0;
    }
    return null;
}

pub fn asDouble(maybe_value: ?*GVariant) ?f64 {
    const value = maybe_value orelse return null;
    const t = getTypeStr(value);
    if (mem.eql(u8, t, "d")) {
        return g_variant_get_double(value);
    } else if (mem.eql(u8, t, "u")) {
        return @floatFromInt(g_variant_get_uint32(value));
    } else if (mem.eql(u8, t, "i")) {
        return @floatFromInt(g_variant_get_int32(value));
    } else if (mem.eql(u8, t, "x")) {
        return @floatFromInt(g_variant_get_int64(value));
    } else if (mem.eql(u8, t, "t")) {
        return @floatFromInt(g_variant_get_uint64(value));
    }
    return null;
}

pub fn asInt64(maybe_value: ?*GVariant) ?i64 {
    const value = maybe_value orelse return null;
    const t = getTypeStr(value);
    if (mem.eql(u8, t, "x")) {
        return g_variant_get_int64(value);
    } else if (mem.eql(u8, t, "t")) {
        const u = g_variant_get_uint64(value);
        return @intCast(@min(u, @as(u64, std.math.maxInt(i64))));
    } else if (mem.eql(u8, t, "i")) {
        return g_variant_get_int32(value);
    } else if (mem.eql(u8, t, "u")) {
        return g_variant_get_uint32(value);
    }
    return null;
}

pub fn asUint32(maybe_value: ?*GVariant) ?u32 {
    const value = maybe_value orelse return null;
    const t = getTypeStr(value);
    if (mem.eql(u8, t, "u")) {
        return g_variant_get_uint32(value);
    } else if (mem.eql(u8, t, "i")) {
        const i = g_variant_get_int32(value);
        return if (i >= 0) @intCast(i) else null;
    } else if (mem.eql(u8, t, "y")) {
        return g_variant_get_byte(value);
    }
    return null;
}

pub fn asByte(maybe_value: ?*GVariant) ?u8 {
    const value = maybe_value orelse return null;
    const t = getTypeStr(value);
    if (mem.eql(u8, t, "y")) {
        return g_variant_get_byte(value);
    } else if (mem.eql(u8, t, "u")) {
        const u = g_variant_get_uint32(value);
        return if (u <= 255) @intCast(u) else null;
    } else if (mem.eql(u8, t, "i")) {
        const i = g_variant_get_int32(value);
        return if (i >= 0 and i <= 255) @intCast(i) else null;
    }
    return null;
}

const testing = std.testing;

test "gdbus variant conversions" {
    // String
    {
        const v = g_variant_new_parsed("'vergebar'") orelse return error.VariantParseFailed;
        defer g_variant_unref(v);
        try testing.expectEqualStrings("s", getTypeStr(v));
        try testing.expectEqualStrings("vergebar", asString(v).?);
        try testing.expect(asBoolean(v) == null);
        try testing.expect(asDouble(v) == null);
    }

    // Boolean
    {
        const v_true = g_variant_new_parsed("true") orelse return error.VariantParseFailed;
        defer g_variant_unref(v_true);
        try testing.expectEqualStrings("b", getTypeStr(v_true));
        try testing.expectEqual(true, asBoolean(v_true).?);

        const v_false = g_variant_new_parsed("false") orelse return error.VariantParseFailed;
        defer g_variant_unref(v_false);
        try testing.expectEqual(false, asBoolean(v_false).?);
    }

    // Double and numeric coercion
    {
        const v_d = g_variant_new_parsed("3.14159") orelse return error.VariantParseFailed;
        defer g_variant_unref(v_d);
        try testing.expectEqualStrings("d", getTypeStr(v_d));
        try testing.expectApproxEqAbs(@as(f64, 3.14159), asDouble(v_d).?, 0.00001);

        const v_u = g_variant_new_parsed("@u 42") orelse return error.VariantParseFailed;
        defer g_variant_unref(v_u);
        try testing.expectEqual(@as(f64, 42.0), asDouble(v_u).?);
        try testing.expectEqual(@as(u32, 42), asUint32(v_u).?);
        try testing.expectEqual(@as(i64, 42), asInt64(v_u).?);
        try testing.expectEqual(@as(u8, 42), asByte(v_u).?);
    }

    // Int64 and negative numbers
    {
        const v_x = g_variant_new_parsed("@x -1234567890123") orelse return error.VariantParseFailed;
        defer g_variant_unref(v_x);
        try testing.expectEqualStrings("x", getTypeStr(v_x));
        try testing.expectEqual(@as(i64, -1234567890123), asInt64(v_x).?);
        try testing.expect(asUint32(v_x) == null);
    }

    // Byte
    {
        const v_y = g_variant_new_parsed("@y 255") orelse return error.VariantParseFailed;
        defer g_variant_unref(v_y);
        try testing.expectEqualStrings("y", getTypeStr(v_y));
        try testing.expectEqual(@as(u8, 255), asByte(v_y).?);
        try testing.expectEqual(@as(u32, 255), asUint32(v_y).?);
    }

    // Dict iteration and boxed variant unwrapping
    {
        const dict = g_variant_new_parsed("{'Percentage': <@d 85.5>, 'State': <@u 2>}") orelse return error.VariantParseFailed;
        defer g_variant_unref(dict);

        const iter = g_variant_iter_new(dict) orelse return error.IterFailed;
        defer g_variant_iter_free(iter);

        var count: usize = 0;
        while (g_variant_iter_next_value(iter)) |entry| {
            defer g_variant_unref(entry);
            count += 1;

            const k_v = g_variant_get_child_value(entry, 0);
            const v_v = g_variant_get_child_value(entry, 1);
            defer if (k_v) |k| g_variant_unref(k);
            defer if (v_v) |v| g_variant_unref(v);

            const key = asString(k_v.?).?;
            const inner = g_variant_get_variant(v_v.?);
            defer g_variant_unref(inner);

            if (mem.eql(u8, key, "Percentage")) {
                try testing.expectApproxEqAbs(@as(f64, 85.5), asDouble(inner).?, 0.001);
            } else if (mem.eql(u8, key, "State")) {
                try testing.expectEqual(@as(u32, 2), asUint32(inner).?);
            }
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
}
