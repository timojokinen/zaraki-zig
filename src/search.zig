const std = @import("std");
const Position = @import("position.zig").Position;
const Move = @import("move.zig").Move;
const MoveList = @import("move.zig").MoveList;
const ScoredMove = @import("move.zig").ScoredMove;
const eval = @import("eval.zig").eval;
const Color = @import("utils.zig").Color;
const scoreMoves = @import("movepick.zig").scoreMoves;

const INF: i32 = 32_000;
const MATE: i32 = 30_000;
const MAX_PLY: usize = 128;

pub const Searcher = struct {
    pv: [MAX_PLY][MAX_PLY]Move = std.mem.zeroes([MAX_PLY][MAX_PLY]Move),
    pv_length: [MAX_PLY]u8 = [_]u8{0} ** MAX_PLY,

    saved_pv: [MAX_PLY]Move = undefined,
    saved_pv_length: usize = 0,

    move_lists: [MAX_PLY]MoveList = std.mem.zeroes([MAX_PLY]MoveList),

    pub fn think(self: *Searcher, position: *Position, max_depth: usize) !Move {
        if (max_depth == 0) return error.InvalidDepth;
        var d: usize = 1;

        while (d <= max_depth) : (d += 1) {
            _ = try negamax(self, position, -INF, INF, d, 0, d > 1);

            self.saved_pv_length = self.pv_length[0];
            @memcpy(self.saved_pv[0..self.saved_pv_length], self.pv[0][0..self.saved_pv_length]);
        }

        return self.pv[0][0];
    }

    pub fn negamax(self: *Searcher, position: *Position, alpha: i32, beta: i32, depth: usize, ply: usize, follow_pv: bool) !i32 {
        if (follow_pv) std.debug.print("follow_pv at ply {}\n", .{ply});
        self.pv_length[ply] = 0;
        if (depth == 0) return quiescenceSearch(self, position, alpha, beta, ply);

        const move_list_ptr = &self.move_lists[ply];
        try position.generateMoves(move_list_ptr);
        const pv_move = if (follow_pv and ply < self.saved_pv_length) self.saved_pv[ply] else null;
        scoreMoves(position, move_list_ptr, pv_move);

        if (move_list_ptr.count == 0) {
            if (!position.inCheck()) return 0; // Stalemate
            return -MATE + @as(i32, @intCast(ply));
        }

        var max: i32 = -INF;
        var a = alpha;

        var i: usize = 0;
        while (i < move_list_ptr.count) : (i += 1) {
            const sm = move_list_ptr.pickNext(i);
            try position.makeMove(sm.move);
            const child_follow_pv = follow_pv and ply < self.saved_pv_length and self.saved_pv[ply].toU16() == sm.move.toU16();
            const score = -(try negamax(self, position, -beta, -a, depth - 1, ply + 1, child_follow_pv));
            try position.unmakeMove(sm.move);

            if (score > max) {
                max = score;
                if (score > a) {
                    a = score;

                    self.pv[ply][0] = sm.move;
                    @memcpy(
                        self.pv[ply][1 .. 1 + self.pv_length[ply + 1]],
                        self.pv[ply + 1][0..self.pv_length[ply + 1]],
                    );
                    self.pv_length[ply] = self.pv_length[ply + 1] + 1;
                }
            }

            if (score >= beta) return max;
        }

        return max;
    }

    fn quiescenceSearch(self: *Searcher, position: *Position, alpha_: i32, beta: i32, ply: usize) !i32 {
        const static_eval = eval(position);
        if (static_eval >= beta) return static_eval;
        var alpha: i32 = if (static_eval > alpha_) static_eval else alpha_;

        const move_list_ptr = &self.move_lists[ply];
        try position.generateMoves(move_list_ptr);
        filterCaptures(move_list_ptr);
        scoreMoves(position, move_list_ptr, null);

        var max = static_eval;
        var i: usize = 0;
        while (i < move_list_ptr.count) : (i += 1) {
            const sm = move_list_ptr.pickNext(i);
            try position.makeMove(sm.move);
            const score = -(try quiescenceSearch(self, position, -beta, -alpha, ply + 1));
            try position.unmakeMove(sm.move);
            if (score >= beta) return score;
            if (score > max) max = score;
            if (score > alpha) alpha = score;
        }
        return max;
    }
};

fn filterCaptures(move_list: *MoveList) void {
    var w: usize = 0;
    for (move_list.moves[0..move_list.count]) |m| {
        const flags = @intFromEnum(m.move.flags);
        if ((flags & 0b1100) != 0) { // capture or promotion bit
            move_list.moves[w] = m;
            w += 1;
        }
    }
    move_list.count = w;
}
