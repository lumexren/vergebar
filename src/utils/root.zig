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
const testing = std.testing;

pub const Config = @import("config/root.zig");
pub const Json = @import("json/root.zig");
pub const Replacer = @import("replacer/root.zig");
pub const Process = @import("process/root.zig");
pub const Watcher = @import("watcher/root.zig");
pub const Context = @import("context.zig");
pub const AppContext = Context;
pub const Module = @import("module/root.zig").Module;
pub const RenderOptions = @import("module/root.zig").RenderOptions;

test {
    _ = testing.refAllDecls(@This());
}
