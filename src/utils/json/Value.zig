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

/// Represents a JSON value supported by the builder.
/// Only a minimal subset of JSON types is supported:
/// - `string`       → JSON string
/// - `array_string` → JSON array of strings
/// - `number`       → JSON integer number
/// - `boolean`      → JSON boolean
///
/// This restricted set is intentional and matches the needs of
/// lightweight, streaming JSON generation scenarios.
pub const Value = union(enum) {
    string: []const u8,
    array_string: []const []const u8,
    number: i64,
    boolean: bool,
};
