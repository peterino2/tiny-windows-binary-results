const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});
    const bindings = b.addTranslateC(.{ .root_source_file = b.path("src/windows.h"), .target = target, .optimize = optimize });
    const win = bindings.createModule();
    win.link_libc = false;
    const exe = b.addExecutable(.{ .name = "hello-dx11-zig", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = false,
    }) });
    exe.subsystem = .windows;
    exe.root_module.addImport("win", win);
    for ([_][]const u8{ "user32", "kernel32", "d3d11", "dxgi", "d3dcompiler_47" }) |lib| exe.root_module.linkSystemLibrary(lib, .{});
    b.installArtifact(exe);
}
