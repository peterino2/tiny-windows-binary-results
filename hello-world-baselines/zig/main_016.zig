// Zig 0.16 adaptation. main.zig preserves the original research snapshot.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    try writer.interface.writeAll("Hello, world!\n");
    try writer.interface.flush();
}
