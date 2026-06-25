const std = @import("std");
const build_options = @import("build_options");
const initTables = @import("tables.zig").initTables;
const initZobristKeys = @import("zobrist.zig").initZobristKeys;
const uci = @import("uci.zig");
const uciInterface = @import("uci.zig").uciInterface;

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [32]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    try stdout.print("Zaraki {s} by Timo Jokinen\n", .{build_options.engine_version});
    try stdout.flush();

    initZobristKeys();
    initTables();
    var uci_interface = uci.UCIInterface.init(init.io, init.gpa);
    try uci_interface.listen();
}
