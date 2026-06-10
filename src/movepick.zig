const Position = @import("position.zig").Position;
const std = @import("std");
const PieceType = @import("piece").PieceType;
const Move = @import("move.zig").Move;
const MoveFlags = @import("move.zig").MoveFlags;
const MoveList = @import("move.zig").MoveList;
const Searcher = @import("search.zig").Searcher;

pub fn scoreMoves(position: *Position, move_list: *MoveList, pv_move: ?Move) void {
    for (move_list.moves[0..move_list.count]) |*scored_move| {
        if (pv_move) |pv| {
            if (pv.toU16() == scored_move.move.toU16()) scored_move.score += 30_000;
        }

        const flags = @intFromEnum(scored_move.move.flags);
        if (flags & @intFromEnum(MoveFlags.CAPTURE) != 0) {
            const mvv_lva_score = scoreMVVLVA(position, scored_move.move);
            scored_move.score += mvv_lva_score;
        }

        // TODO: Replace with SEE (Static Exchange Evaluation) probably
        if ((flags & @intFromEnum(MoveFlags.QUEEN_PROMOTION)) == @intFromEnum(MoveFlags.QUEEN_PROMOTION)) {
            scored_move.score += 1_000;
        }
    }
}

const MVV_LVA = [6][6]i32{
    .{ 205, 204, 203, 202, 201, 200 }, // Pawn
    .{ 305, 304, 303, 302, 301, 300 }, // Knight
    .{ 405, 404, 403, 402, 401, 400 }, // Bishop
    .{ 505, 504, 503, 502, 501, 500 }, // Rook
    .{ 605, 604, 603, 602, 601, 600 }, // Queen
    .{ 705, 704, 703, 702, 701, 700 }, // King as victim unused in legal play but exists for bounds safety
};

pub fn scoreMVVLVA(position: *Position, move: Move) i32 {
    const victim = position.pieceAt(move.to_sq) orelse .Pawn; // En-Passant
    std.debug.assert(victim != .King);
    const attacker = position.pieceAt(move.from_sq) orelse unreachable;
    return MVV_LVA[@intFromEnum(victim)][@intFromEnum(attacker)];
}
