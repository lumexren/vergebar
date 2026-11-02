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

const CPU = @This();

pub const CPUError = @import("CPUError.zig").CPUError;
pub const Sample = @import("Sample.zig");
pub const FrequencyValue = @import("FrequencyValue.zig");
pub const Frequency = @import("Frequency.zig");
pub const FrequencyRange = @import("FrequencyRange.zig");
pub const CoreInfo = @import("CoreInfo.zig");
pub const LoadAvg = struct {
    one: f64 = 0.0,
    five: f64 = 0.0,
    fifteen: f64 = 0.0,
};

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const Io = std.Io;
const Threaded = Io.Threaded;
const Dir = Io.Dir;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const STAT_BUFFER_SIZE: usize = 16 * 1024;
const SYSFS_PATH_MAX: usize = 96;
const BASELINE_SLEEP_MS: u64 = 100;

io: Io,
allocator: Allocator,
prev_overall: Sample = .{ .idle = 0, .total = 0 },
prev_cores: []Sample = &.{},
overall: f64 = 0.0,
avg: f64 = 0.0,
load_avg: LoadAvg = .{},
cores: []CoreInfo = &.{},
scratch_samples: ArrayList(Sample) = .empty,

pub fn init(io: Io, allocator: Allocator) CPU {
    return .{ .io = io, .allocator = allocator };
}

pub fn deinit(self: *CPU) void {
    self.allocator.free(self.prev_cores);
    self.allocator.free(self.cores);
    self.scratch_samples.deinit(self.allocator);
}

/// Updates CPU usage metrics and frequencies.
pub fn update(self: *CPU) !void {
    if (self.prev_cores.len == 0)
        try self.initBaseline();

    var curr_overall: Sample = undefined;
    try self.captureSnapshot(&curr_overall);

    if (self.scratch_samples.items.len != self.prev_cores.len)
        return CPUError.CoreCountChanged;

    self.overall = computeUsage(self.prev_overall, curr_overall);
    self.avg = self.computeAvg();
    self.updateFrequencies();
    self.updateLoadAvg();

    self.prev_overall = curr_overall;
    @memcpy(self.prev_cores, self.scratch_samples.items);
}

fn initBaseline(self: *CPU) !void {
    try self.captureSnapshot(&self.prev_overall);
    self.updateLoadAvg();

    const core_count = self.scratch_samples.items.len;

    const prev_cores = try self.allocator.alloc(Sample, core_count);
    errdefer self.allocator.free(prev_cores);

    const cores = try self.allocator.alloc(CoreInfo, core_count);
    errdefer self.allocator.free(cores);

    @memcpy(prev_cores, self.scratch_samples.items);
    @memset(cores, .{});

    self.prev_cores = prev_cores;
    self.cores = cores;

    try self.io.sleep(.fromMilliseconds(BASELINE_SLEEP_MS), .boot);
}

fn updateLoadAvg(self: *CPU) void {
    var file = Dir.openFileAbsolute(self.io, "/proc/loadavg", .{ .mode = .read_only }) catch return;
    defer file.close(self.io);

    var buffer: [64]u8 = undefined;
    var reader = file.reader(self.io, &.{});
    const bytes_read = reader.interface.readSliceShort(&buffer) catch return;
    if (bytes_read == 0) return;

    self.load_avg = parseLoadAvg(buffer[0..bytes_read]) catch return;
}

pub fn parseLoadAvg(line: []const u8) CPUError!LoadAvg {
    var it = mem.tokenizeScalar(u8, line, ' ');
    const s1 = it.next() orelse return CPUError.UnexpectedFormat;
    const s5 = it.next() orelse return CPUError.UnexpectedFormat;
    const s15 = it.next() orelse return CPUError.UnexpectedFormat;

    const one = fmt.parseFloat(f64, s1) catch return CPUError.UnexpectedFormat;
    const five = fmt.parseFloat(f64, s5) catch return CPUError.UnexpectedFormat;
    const fifteen = fmt.parseFloat(f64, s15) catch return CPUError.UnexpectedFormat;

    return .{ .one = one, .five = five, .fifteen = fifteen };
}

fn captureSnapshot(self: *CPU, overall: *Sample) !void {
    self.scratch_samples.clearRetainingCapacity();

    var file = try Dir.openFileAbsolute(self.io, "/proc/stat", .{ .mode = .read_only });
    defer file.close(self.io);

    var buffer: [STAT_BUFFER_SIZE]u8 = undefined;
    var reader = file.reader(self.io, &.{});
    const bytes_read = try reader.interface.readSliceShort(&buffer);

    if (bytes_read == 0) return CPUError.UnexpectedFormat;

    var have_overall = false;
    var lines = mem.splitScalar(u8, buffer[0..bytes_read], '\n');

    while (lines.next()) |raw| {
        const line = mem.trimStart(u8, raw, " \t");
        if (!mem.startsWith(u8, line, "cpu")) break;

        if (line.len <= 3) continue;

        if (line[3] == ' ' or line[3] == '\t') {
            overall.* = try parseLine(line);
            have_overall = true;
        } else if (ascii.isDigit(line[3])) {
            try self.scratch_samples.append(self.allocator, try parseLine(line));
        }
    }

    if (!have_overall) return CPUError.UnexpectedFormat;
}

fn computeAvg(self: *const CPU) f64 {
    if (self.cores.len == 0) return 0.0;

    var sum: f64 = 0.0;
    for (self.prev_cores, self.scratch_samples.items, 0..) |prev, curr, i| {
        const usage = computeUsage(prev, curr);
        self.cores[i].usage = usage;
        sum += usage;
    }

    return sum / @as(f64, @floatFromInt(self.cores.len));
}

fn updateFrequencies(self: *CPU) void {
    var path_buf: [SYSFS_PATH_MAX]u8 = undefined;

    for (self.cores, 0..) |*core, i| {
        core.frequency = .{
            .min = readSysfsFrequency(self.io, mem.print(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/cpuinfo_min_freq", .{i}) catch return),
            .max = readSysfsFrequency(self.io, mem.print(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/cpuinfo_max_freq", .{i}) catch return),
            .current = readSysfsFrequency(self.io, mem.print(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/scaling_cur_freq", .{i}) catch return),
        };
    }
}

pub inline fn parseLine(line: []const u8) CPUError!Sample {
    var it = mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return CPUError.UnexpectedFormat;

    var fields: [8]u64 = @splat(0);
    var idx: usize = 0;

    while (it.next()) |tok| : (idx += 1) {
        if (idx >= 8) break;
        fields[idx] = fmt.parseInt(u64, tok, 10) catch return CPUError.UnexpectedFormat;
    }

    if (idx < 4) return CPUError.UnexpectedFormat;

    const idle_all = fields[3] + fields[4];
    const non_idle = fields[0] + fields[1] + fields[2] + fields[5] + fields[6] + fields[7];

    return .{ .idle = idle_all, .total = idle_all + non_idle };
}

pub inline fn computeUsage(a: Sample, b: Sample) f64 {
    if (b.total <= a.total or b.idle < a.idle) return 0.0;

    const totald = b.total - a.total;
    const idled = b.idle - a.idle;

    if (idled > totald) return 0.0;

    return (@as(f64, @floatFromInt(totald)) - @as(f64, @floatFromInt(idled))) /
        @as(f64, @floatFromInt(totald)) * 100.0;
}

pub inline fn calculateFrequency(mhz: f64) Frequency {
    const is_ghz = mhz >= 1000.0;
    const value = if (is_ghz) mhz * 0.001 else mhz;
    const rounded: i64 = @intFromFloat(@round(value));
    const rounded_f: f64 = @floatFromInt(rounded);

    return .{
        .value = .{
            .raw = value,
            .rounded = rounded,
            .fraction = @abs(value - rounded_f) > 0.001,
        },
        .unit = if (is_ghz) "GHz" else "MHz",
    };
}

fn readSysfsFrequency(io: Io, path: []const u8) Frequency {
    var file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return .{};
    defer file.close(io);

    var buf: [32]u8 = undefined;
    var reader = file.reader(io, &.{});
    const bytes_read = reader.interface.readSliceShort(&buf) catch return .{};
    const line = mem.trim(u8, buf[0..bytes_read], " \t\n\r");
    const khz = fmt.parseInt(u64, line, 10) catch return .{};

    return calculateFrequency(@as(f64, @floatFromInt(khz)) * 0.001);
}

const testing = std.testing;

test "cpu lifecycle and update integration" {
    const allocator = testing.allocator;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    var cpu: CPU = .init(io, allocator);
    defer cpu.deinit();

    cpu.update() catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    try testing.expect(cpu.cores.len > 0);
    try testing.expect(cpu.prev_cores.len == cpu.cores.len);

    try io.sleep(.fromMilliseconds(50), .boot);

    try cpu.update();

    try testing.expect(cpu.overall >= 0.0 and cpu.overall <= 100.0);
    try testing.expect(cpu.avg >= 0.0 and cpu.avg <= 100.0);

    for (cpu.cores) |core| {
        try testing.expect(core.usage >= 0.0 and core.usage <= 100.0);
        try testing.expect(core.frequency.current.value.raw >= 0.0);
    }
}

test "parseLine" {
    const line = "cpu  100 200 300 400 500 600 700 800";
    const s = try parseLine(line);
    try testing.expectEqual(@as(u64, 900), s.idle);
    try testing.expectEqual(@as(u64, 3600), s.total);

    const line2 = "cpu0 10 20 30 40 50 60 70 80";
    const s2 = try parseLine(line2);
    try testing.expectEqual(@as(u64, 90), s2.idle);
    try testing.expectEqual(@as(u64, 360), s2.total);

    try testing.expectError(CPUError.UnexpectedFormat, parseLine("cpu  10 20 30"));
    try testing.expectError(CPUError.UnexpectedFormat, parseLine("cpu  10 20 abc 40"));
}

test "computeUsage" {
    const s0 = Sample{ .idle = 0, .total = 0 };
    const s1 = Sample{ .idle = 50, .total = 100 };
    const s2 = Sample{ .idle = 100, .total = 200 };
    const s3 = Sample{ .idle = 50, .total = 100 };

    try testing.expectApproxEqAbs(@as(f64, 50.0), computeUsage(s0, s1), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 50.0), computeUsage(s1, s2), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s3), 0.001);

    const s_busy = Sample{ .idle = 50, .total = 200 };
    try testing.expectApproxEqAbs(@as(f64, 100.0), computeUsage(s1, s_busy), 0.001);

    const s_idle = Sample{ .idle = 150, .total = 200 };
    try testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_idle), 0.001);

    const s_wrap = Sample{ .idle = 10, .total = 50 };
    try testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_wrap), 0.001);

    const s_idle_dec = Sample{ .idle = 30, .total = 150 };
    try testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_idle_dec), 0.001);
}

test "calculateFrequency" {
    const f1 = calculateFrequency(800.0);
    try testing.expectEqualStrings("MHz", f1.unit);
    try testing.expectApproxEqAbs(@as(f64, 800.0), f1.value.raw, 0.001);
    try testing.expectEqual(@as(i64, 800), f1.value.rounded);
    try testing.expectEqual(false, f1.value.fraction);

    const f2 = calculateFrequency(2500.0);
    try testing.expectEqualStrings("GHz", f2.unit);
    try testing.expectApproxEqAbs(@as(f64, 2.5), f2.value.raw, 0.001);
    try testing.expectEqual(@as(i64, 3), f2.value.rounded);
    try testing.expectEqual(true, f2.value.fraction);

    const f3 = calculateFrequency(3000.0);
    try testing.expectEqualStrings("GHz", f3.unit);
    try testing.expectApproxEqAbs(@as(f64, 3.0), f3.value.raw, 0.001);
    try testing.expectEqual(@as(i64, 3), f3.value.rounded);
    try testing.expectEqual(false, f3.value.fraction);

    const f4 = calculateFrequency(800.0000001);
    try testing.expectEqualStrings("MHz", f4.unit);
    try testing.expectEqual(false, f4.value.fraction);
}

test "parseLoadAvg" {
    const raw = "0.52 0.48 0.45 2/1234 56789\n";
    const l = try parseLoadAvg(raw);
    try testing.expectApproxEqAbs(@as(f64, 0.52), l.one, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.48), l.five, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.45), l.fifteen, 0.001);

    try testing.expectError(CPUError.UnexpectedFormat, parseLoadAvg("0.52"));
    try testing.expectError(CPUError.UnexpectedFormat, parseLoadAvg("abc def ghi"));
}
