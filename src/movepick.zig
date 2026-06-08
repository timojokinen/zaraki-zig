const Position = @import("position.zig").Position;
const std = @import("std");

pub fn sortMoves(moves: []Move) void {
    std.mem.sortUnstable(Move, moves[], {}, )
}

/// fn sortFn()
