const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});
    const bindings = b.addTranslateC(.{
        .root_source_file = b.path("src/windows.h"), .target = target, .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "hello-opengl-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize,
            .link_libc = false,
        }),
    });
    exe.subsystem = .windows;
    // Translation uses Zig's Windows SDK headers, but importing those declarations
    // must not enable the C runtime in the final executable.
    const win = bindings.createModule();
    win.link_libc = false;
    exe.root_module.addImport("win", win);
    for ([_][]const u8{ "user32", "kernel32", "gdi32", "opengl32" }) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Open the OpenGL triangle window").dependOn(&run.step);
}
