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
const Build = std.Build;
const ArrayList = std.ArrayList;
const SemanticVersion = std.SemanticVersion;
const LtoMode = std.zig.LtoMode;

const Version: SemanticVersion = .{ .major = 1, .minor = 0, .patch = 0 };
const version_string = "1.0.0";

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lto: LtoMode = switch (optimize) {
        .debug, .safe => .none,
        .small => .thin,
        .fast => .full,
    };

    // GPU library options
    const link_gpu = b.option(bool, "link-gpu", "Link GPU libraries (AMD-SMI / NVML) directly at compile time") orelse false;

    const has_amdsmi = link_gpu;
    const has_nvml = link_gpu;

    const options = b.addOptions();
    options.addOption(bool, "has_amdsmi", has_amdsmi);
    options.addOption(bool, "has_nvml", has_nvml);
    options.addOption([]const u8, "version", version_string);
    const build_options = options.createModule();

    const bindings = b.addModule("bindings", .{
        .root_source_file = b.path("src/bindings/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bindings.addCSourceFile(.{
        .file = b.path("src/bindings/pipewire/wrapper.c"),
        .flags = &.{"-std=c11"},
    });
    bindings.addIncludePath(.{ .cwd_relative = "/usr/include/pipewire-0.3" });
    bindings.addIncludePath(.{ .cwd_relative = "/usr/include/spa-0.2" });
    bindings.linkSystemLibrary("pipewire-0.3", .{});
    bindings.linkSystemLibrary("gio-2.0", .{});
    bindings.linkSystemLibrary("glib-2.0", .{});
    bindings.linkSystemLibrary("m", .{});

    const utils_mod = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "bindings", .module = bindings },
        },
    });

    const sysinfo_mod = b.addModule("sysinfo", .{
        .root_source_file = b.path("src/sysinfo/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "bindings", .module = bindings },
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "build_options", .module = build_options },
        },
    });
    sysinfo_mod.linkSystemLibrary("pipewire-0.3", .{});
    sysinfo_mod.linkSystemLibrary("gio-2.0", .{});
    sysinfo_mod.linkSystemLibrary("glib-2.0", .{});
    sysinfo_mod.linkSystemLibrary("m", .{});

    const gtk_mod = b.addModule("gtk", .{
        .root_source_file = b.path("src/bindings/gtk.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "bindings", .module = bindings },
            .{ .name = "sysinfo", .module = sysinfo_mod },
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "gtk", .module = gtk_mod },
            .{ .name = "build_options", .module = build_options },
        },
    });
    exe_mod.linkSystemLibrary("gtk4", .{});
    exe_mod.linkSystemLibrary("gtk4-layer-shell-0", .{});
    exe_mod.linkSystemLibrary("gio-2.0", .{});
    exe_mod.linkSystemLibrary("glib-2.0", .{});
    exe_mod.linkSystemLibrary("gobject-2.0", .{});
    exe_mod.linkSystemLibrary("pipewire-0.3", .{});
    exe_mod.linkSystemLibrary("m", .{});

    const exe = b.addExecutable(.{
        .name = "vergebar",
        .root_module = exe_mod,
        .version = Version,
    });
    exe.lto = lto;

    b.installArtifact(exe);

    const check_step = b.step("check", "Check compilation of all artifacts");
    check_step.dependOn(&exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run vergebar");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    const bindings_tests = b.addTest(.{
        .root_module = bindings,
    });
    const run_bindings_tests = b.addRunArtifact(bindings_tests);
    test_step.dependOn(&run_bindings_tests.step);

    const sysinfo_tests = b.addTest(.{
        .root_module = sysinfo_mod,
    });
    const run_sysinfo_tests = b.addRunArtifact(sysinfo_tests);
    test_step.dependOn(&run_sysinfo_tests.step);

    const utils_tests = b.addTest(.{
        .root_module = utils_mod,
    });
    const run_utils_tests = b.addRunArtifact(utils_tests);
    test_step.dependOn(&run_utils_tests.step);
}
