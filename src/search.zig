const std = @import("std");
const Position = @import("position.zig").Position;
const Move = @import("move.zig").Move;
const MoveList = @import("move.zig").MoveList;
const ScoredMove = @import("move.zig").ScoredMove;
const eval = @import("eval.zig").eval;
const Color = @import("utils.zig").Color;
const scoreMoves = @import("movepick.zig").scoreMoves;
const TranspositionTable = @import("tt.zig").TranspositionTable;
const NodeType = @import("tt.zig").NodeType;

const INF: i32 = 32_000;
const MATE: i32 = 30_000;
const MAX_PLY: usize = 128;

pub const Searcher = struct {
    tt: *TranspositionTable,
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    tt_size_mb: usize = 64,

    pv: [MAX_PLY][MAX_PLY]Move = std.mem.zeroes([MAX_PLY][MAX_PLY]Move),
    pv_length: [MAX_PLY]u8 = [_]u8{0} ** MAX_PLY,

    saved_pv: [MAX_PLY]Move = undefined,
    saved_pv_length: usize = 0,

    move_lists: [MAX_PLY]MoveList = std.mem.zeroes([MAX_PLY]MoveList),
    nodes: usize = 0,

    pub fn think(self: *Searcher, position: *Position, max_depth: usize) !Move {
        if (max_depth == 0) return error.InvalidDepth;
        self.nodes = 0;
        const start = std.Io.Clock.now(.awake, self.io);
        self.saved_pv_length = 0;
        var d: usize = 1;
        while (d <= max_depth) : (d += 1) {
            _ = try negamax(self, position, -INF, INF, d, 0, d > 1);

            self.saved_pv_length = self.pv_length[0];
            @memcpy(self.saved_pv[0..self.saved_pv_length], self.pv[0][0..self.saved_pv_length]);
            const elapsed_ns = start.durationTo(std.Io.Clock.now(.awake, self.io)).toNanoseconds();
            const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);
            const nps = if (elapsed_ns > 0)
                @divTrunc(self.nodes * 1_000_000_000, @as(u64, @intCast(elapsed_ns)))
            else
                0;

            try self.stdout.print("info depth {} nodes {} time {} nps {}\n", .{
                d, self.nodes, elapsed_ms, nps,
            });
            try self.stdout.flush();
        }

        return self.pv[0][0];
    }

    fn negamax(self: *Searcher, position: *Position, alpha: i32, beta: i32, depth: usize, ply: usize, follow_pv: bool) !i32 {
        self.pv_length[ply] = 0;

        if (depth == 0) return quiescenceSearch(self, position, alpha, beta, ply);

        self.nodes += 1;
        const tt_entry = self.tt.get(position.hash);
        const hash_move: ?Move = if (tt_entry.node_type != .NONE) tt_entry.hash_move else null;

        if (tt_entry.depth >= @as(u8, @intCast(depth))) {
            if (tt_entry.node_type == .EXACT) {
                return tt_entry.score;
            }

            if (tt_entry.node_type == .LOWERBOUND) {
                if (tt_entry.score >= beta) return tt_entry.score;
            }

            if (tt_entry.node_type == .UPPERBOUND) {
                if (tt_entry.score <= alpha) return tt_entry.score;
            }
        }

        const move_list_ptr = &self.move_lists[ply];
        try position.generateMoves(move_list_ptr);
        const pv_move = if (follow_pv and ply < self.saved_pv_length) self.saved_pv[ply] else null;
        scoreMoves(position, move_list_ptr, hash_move, pv_move);

        if (move_list_ptr.count == 0) {
            if (!position.inCheck()) return 0; // Stalemate
            return -MATE + @as(i32, @intCast(ply));
        }

        var max: i32 = -INF;
        var a = alpha;
        var best_move: ?Move = null;

        var i: usize = 0;
        while (i < move_list_ptr.count) : (i += 1) {
            const sm = move_list_ptr.pickNext(i);
            try position.makeMove(sm.move);
            const child_follow_pv = follow_pv and ply < self.saved_pv_length and self.saved_pv[ply].toU16() == sm.move.toU16();
            const score = -(try negamax(self, position, -beta, -a, depth - 1, ply + 1, child_follow_pv));
            try position.unmakeMove(sm.move);

            if (score >= beta) {
                self.tt.set(position.hash, .{
                    .score = score,
                    .hash = position.hash,
                    .hash_move = sm.move,
                    .depth = @intCast(depth),
                    .node_type = .LOWERBOUND,
                });
                return score;
            }
            if (score > max) {
                best_move = sm.move;
                max = score;
            }
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

        const node_type: NodeType = if (max > alpha) .EXACT else .UPPERBOUND;
        self.tt.set(position.hash, .{
            .score = max,
            .hash = position.hash,
            .hash_move = best_move.?,
            .depth = @intCast(depth),
            .node_type = node_type,
        });

        return max;
    }

    fn quiescenceSearch(self: *Searcher, position: *Position, alpha_: i32, beta: i32, ply: usize) !i32 {
        self.nodes += 1;
        const static_eval = eval(position);
        if (static_eval >= beta) return static_eval;
        var alpha: i32 = if (static_eval > alpha_) static_eval else alpha_;

        const move_list_ptr = &self.move_lists[ply];
        try position.generateMoves(move_list_ptr);
        filterCaptures(move_list_ptr);
        scoreMoves(position, move_list_ptr, null, null);

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

// TODO: Make qsearch generate captures only
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
