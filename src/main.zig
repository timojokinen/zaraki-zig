const std = @import("std");
const initTables = @import("tables.zig").initTables;
const initZobristKeys = @import("zobrist.zig").initZobristKeys;
const uciInterface = @import("uci.zig").uciInterface;

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [32]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    try stdout.writeAll("Zaraki 0.1 by Timo Jokinen\n");
    try stdout.flush();

    initZobristKeys();
    initTables();
    try uciInterface(init.io, init.gpa);
}
