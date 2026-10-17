//! A package that uses zpdf the way any Zig project would, from a fetched copy: CI archives the
//! commit, `zig fetch --save=zpdf`es it here, builds and runs this. README.md's Zig example is
//! this file's and src/main.zig's readme blocks (zig build test checks that).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // readme: zig-build
    const zpdf = b.dependency("zpdf", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "hello", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zpdf", .module = zpdf.module("zpdf") }},
    }) });
    // readme: end
    b.installArtifact(exe);
    b.step("run", "Write hello.pdf").dependOn(&b.addRunArtifact(exe).step);
}
