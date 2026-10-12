const std = @import("std");

pub fn main() !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("Hello, world!\n");
    try stdout.flush();
}
