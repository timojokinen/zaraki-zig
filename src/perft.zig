const Move = @import("move.zig").Move;
const MoveList = @import("move.zig").MoveList;
const std = @import("std");
const Position = @import("position.zig").Position;
const createPositionFromFEN = @import("position.zig").createPositionFromFEN;
const utils = @import("utils.zig");

pub fn perft(io: std.Io, position: *Position, depth: usize) !usize {
    if (depth == 0) return 1;
    var timer = std.Io.Clock.now(.awake, io);
    var move_list = MoveList{};
    try position.generateMoves(&move_list);

    if (depth == 1) return move_list.count;
    var total: usize = 0;
    for (move_list.moves[0..move_list.count]) |m| {
        try position.makeMove(m.move);
        const nodes = try perftInner(position, depth - 1);
        position.unmakeMove(m.move);

        std.debug.print("{s}{s}: {d}\n", .{ utils.idx2san(m.move.from_sq), utils.idx2san(m.move.to_sq), nodes });
        total += nodes;
    }

    std.debug.print("\nNodes searched: {d}\n", .{total});

    const elapsed_ns = timer.durationTo(std.Io.Clock.now(.awake, io)).toNanoseconds();
    const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);
    std.debug.print("elapsed ms {}", .{elapsed_ms});
    return total;
}

fn perftInner(position: *Position, depth: usize) !usize {
    var move_list = MoveList{};
    try position.generateMoves(&move_list);

    if (depth == 1) return move_list.count;
    if (depth == 0) return 1;
    var nodes: usize = 0;
    for (move_list.moves[0..move_list.count]) |m| {
        try position.makeMove(m.move);
        nodes += try perftInner(position, depth - 1);
        position.unmakeMove(m.move);
    }

    return nodes;
}
