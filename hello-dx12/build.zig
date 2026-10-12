const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});
    const bindings = b.addTranslateC(.{
        .root_source_file = b.path("src/windows.h"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "hello-dx12",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("win", bindings.createModule());
    for ([_][]const u8{ "user32", "kernel32", "d3d12", "dxgi", "d3dcompiler_47", "dxguid" }) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Open the DirectX 12 triangle window").dependOn(&run.step);
}
