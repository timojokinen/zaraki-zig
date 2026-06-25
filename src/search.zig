const std = @import("std");
const Position = @import("position.zig").Position;
const Move = @import("move.zig").Move;
const MoveList = @import("move.zig").MoveList;
const MoveFlags = @import("move.zig").MoveFlags;
const ScoredMove = @import("move.zig").ScoredMove;
const eval = @import("eval.zig").eval;
const Color = @import("utils.zig").Color;
const utils = @import("utils.zig");
const PieceType = @import("piece.zig").PieceType;
const scoreMoves = @import("movepick.zig").scoreMoves;
const TranspositionTable = @import("tt.zig").TranspositionTable;
const NodeType = @import("tt.zig").NodeType;
const tables = @import("tables.zig");
const movepick = @import("movepick.zig");

const INF: i32 = 32_000;
const MAX_SEARCH_PLY: usize = 128;
const MAX_GAME_PLY: usize = 1024;
const MAX_HASH_HISTORY: usize = MAX_SEARCH_PLY + MAX_GAME_PLY;
const MATE: i32 = 30_000;
const MATE_THRESHOLD: i32 = MATE - @as(i32, MAX_SEARCH_PLY);

const REP_TABLE_BITS = 12;
const REP_TABLE_SIZE = 1 << REP_TABLE_BITS;
const REP_TABLE_MASK = REP_TABLE_SIZE - 1;

fn scoreToTT(score: i32, ply: usize) i32 {
    if (score > MATE_THRESHOLD) return score + @as(i32, @intCast(ply));
    if (score < -MATE_THRESHOLD) return score - @as(i32, @intCast(ply));
    return score;
}

fn scoreFromTT(score: i32, ply: usize) i32 {
    if (score > MATE_THRESHOLD) return score - @as(i32, @intCast(ply));
    if (score < -MATE_THRESHOLD) return score + @as(i32, @intCast(ply));
    return score;
}

const SearcherError = error{SearchStopped};

pub const SearchLimits = struct {
    depth: ?usize = null,
    movetime_ms: ?u64 = null,
    wtime_ms: ?u64 = null,
    btime_ms: ?u64 = null,
    winc_ms: ?u64 = null,
    binc_ms: ?u64 = null,
    infinite: bool = false,
    perft: ?usize = null,
};

pub const Searcher = struct {
    tt: *TranspositionTable,
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    tt_size_mb: usize = 64,

    pv: [MAX_SEARCH_PLY][MAX_SEARCH_PLY]Move = std.mem.zeroes([MAX_SEARCH_PLY][MAX_SEARCH_PLY]Move),
    pv_length: [MAX_SEARCH_PLY]u8 = [_]u8{0} ** MAX_SEARCH_PLY,

    saved_pv: [MAX_SEARCH_PLY]Move = undefined,
    saved_pv_length: usize = 0,

    move_lists: [MAX_SEARCH_PLY]MoveList = std.mem.zeroes([MAX_SEARCH_PLY]MoveList),
    nodes: usize = 0,

    history: [2][64][64]i32 = undefined,
    killers: [MAX_SEARCH_PLY][2]Move = undefined,

    should_stop: bool = false,
    move_time_millis: usize = 0,
    timer: ?std.Io.Timestamp = null,

    best_move_so_far: ?Move = null,
    depth_completed: usize = 0,

    hash_history: [MAX_HASH_HISTORY]u64 = std.mem.zeroes([MAX_HASH_HISTORY]u64),
    hash_history_length: usize = 0,
    repetition_table: [4096]u16 = [_]u16{0} ** REP_TABLE_SIZE,

    pub fn resetPerSearch(self: *Searcher) void {
        self.nodes = 0;
        self.should_stop = false;
        self.saved_pv_length = 0;
        self.pv_length = [_]u8{0} ** MAX_SEARCH_PLY;
        self.pv = std.mem.zeroes([MAX_SEARCH_PLY][MAX_SEARCH_PLY]Move);
        self.killers = std.mem.zeroes([MAX_SEARCH_PLY][2]Move);
        self.history = std.mem.zeroes([2][64][64]i32);
    }

    pub fn resetPerGame(self: *Searcher) void {
        self.resetPerSearch();
        self.tt.clear();
        self.resetPerNewPosition();
    }

    pub fn resetPerNewPosition(self: *Searcher) void {
        self.hash_history_length = 0;
        self.repetition_table = [_]u16{0} ** REP_TABLE_SIZE;
    }

    pub fn pushRepetition(self: *Searcher, hash: u64) void {
        self.hash_history[self.hash_history_length] = hash;
        self.repetition_table[@intCast(hash & REP_TABLE_MASK)] += 1;
        self.hash_history_length += 1;
    }

    pub fn popRepetition(self: *Searcher) void {
        self.hash_history_length -= 1;
        const hash = self.hash_history[self.hash_history_length];
        self.repetition_table[@intCast(hash & REP_TABLE_MASK)] -= 1;
    }

    pub fn isDrawByRepetitionOrRule50(self: *Searcher, position: *Position) bool {
        // 50 move rule check
        if (position.board_state.halfmove_clock >= 100) return true;

        // 3-fold repetition check
        const rep_table_idx: usize = @intCast(position.hash & REP_TABLE_MASK);
        if (self.repetition_table[rep_table_idx] < 3) return false;

        var i = self.hash_history_length;
        var matches: usize = 0;
        while (i > 0) {
            i -= 1;
            if (self.hash_history[i] == position.hash) {
                matches += 1;
            }
            if (matches >= 3) return true;
        }

        return false;
    }

    pub fn think(self: *Searcher, position: *Position, search_limits: SearchLimits) !Move {
        const depth = search_limits.depth orelse 99;
        const movetime_budget_ms = self.computeBudget(search_limits, position.board_state.side_to_move);
        self.move_time_millis = movetime_budget_ms orelse 0;
        if (depth == 0) return error.InvalidDepth;
        self.resetPerSearch();

        self.timer = std.Io.Clock.now(.awake, self.io);
        var d: usize = 1;
        var prev_score: i32 = 0;
        outer: while (d <= depth) : (d += 1) {
            var delta: i32 = 25;
            var alpha = if (d >= 4) prev_score - delta else -INF;
            var beta = if (d >= 4) prev_score + delta else INF;

            inner: while (true) {
                const score = negamax(self, position, alpha, beta, d, 0, true, false, true) catch |err| switch (err) {
                    SearcherError.SearchStopped => break :outer,
                    else => return err,
                };

                if (score <= alpha) {
                    alpha = @max(score - delta, -INF);
                    delta *= 2;
                } else if (score >= beta) {
                    beta = @min(score + delta, INF);
                    delta *= 2;
                } else {
                    prev_score = score;
                    break :inner;
                }
            }

            self.saved_pv_length = self.pv_length[0];
            @memcpy(self.saved_pv[0..self.saved_pv_length], self.pv[0][0..self.saved_pv_length]);
            self.best_move_so_far = self.pv[0][0];
            const elapsed_ns = self.timer.?.durationTo(std.Io.Clock.now(.awake, self.io)).toNanoseconds();
            const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);
            const nps = if (elapsed_ns > 0)
                @divTrunc(self.nodes * 1_000_000_000, @as(u64, @intCast(elapsed_ns)))
            else
                0;

            try self.stdout.print("info depth {} nodes {} time {} nps {}\n", .{
                d, self.nodes, elapsed_ms, nps,
            });
            try self.stdout.flush();
            self.depth_completed = d;
        }

        return self.best_move_so_far orelse self.pv[0][0];
    }

    fn negamax(self: *Searcher, position: *Position, alpha: i32, beta: i32, _depth: usize, ply: usize, is_root: bool, is_null: bool, is_pv: bool) !i32 {
        self.pv_length[ply] = 0;
        var depth: usize = _depth;

        if (depth == 0) return quiescenceSearch(self, position, alpha, beta, ply);

        self.nodes += 1;

        if (self.nodes & 4095 == 0 and self.shouldStop() and self.depth_completed >= 1) {
            return error.SearchStopped;
        }

        // Check 3fold repetition
        if (self.isDrawByRepetitionOrRule50(position)) {
            return 0;
        }

        // TT-Probe
        const tt_entry = self.tt.get(position.hash);
        const hash_move: ?Move = if (tt_entry.node_type != .NONE) tt_entry.hash_move else null;

        if (tt_entry.depth >= @as(u8, @intCast(depth)) and !is_root) {
            const adjusted_score = scoreFromTT(tt_entry.score, ply);
            if (tt_entry.node_type == .EXACT) {
                return adjusted_score;
            }

            if (tt_entry.node_type == .LOWERBOUND) {
                if (adjusted_score >= beta) return adjusted_score;
            }

            if (tt_entry.node_type == .UPPERBOUND) {
                if (adjusted_score <= alpha) return adjusted_score;
            }
        }

        const move_list_ptr = &self.move_lists[ply];
        try position.generateMoves(move_list_ptr);
        scoreMoves(position, self, ply, move_list_ptr, hash_move);

        if (move_list_ptr.count == 0) {
            if (!position.inCheck()) return 0; // Stalemate
            return -MATE + @as(i32, @intCast(ply));
        }

        if (position.inCheck()) depth += 1;

        // Null-Move-Pruning
        const color_offset: usize = if (position.board_state.side_to_move == .Black) 6 else 0;
        const non_king_pawns = (position.bbs[@intFromEnum(PieceType.Bishop) + color_offset] | position.bbs[@intFromEnum(PieceType.Knight) + color_offset] | position.bbs[@intFromEnum(PieceType.Rook) + color_offset] | position.bbs[@intFromEnum(PieceType.Queen) + color_offset]) != 0;
        if (!is_null and !is_root and !position.inCheck() and non_king_pawns and depth >= 3) {
            var R: usize = 2 + @divTrunc(depth, 6);
            R = @min(R, depth);
            position.makeNullMove();
            const score = -(try negamax(self, position, -beta, -(beta - 1), depth - R, ply + 1, false, true, false));
            position.unmakeNullMove();

            if (score >= beta) {
                return score;
            }
        }

        // Search Loop
        var max: i32 = -INF;
        var a = alpha;
        var best_move: ?Move = null;

        var i: usize = 0;
        while (i < move_list_ptr.count) : (i += 1) {
            const sm = move_list_ptr.pickNext(i);
            try position.makeMove(sm.move);
            self.pushRepetition(position.hash);

            const child_is_pv = i == 0 and is_pv;

            var score: i32 = undefined;

            if (child_is_pv) {
                score = -(try negamax(self, position, -beta, -a, depth - 1, ply + 1, false, false, true));
            } else {
                const flags_int = @intFromEnum(sm.move.flags);
                const is_quiet = (flags_int & 0b1100) == 0;
                const do_lmr = depth >= 3 and i >= 3 and !position.inCheck() and is_quiet;
                const reduction = if (do_lmr) tables.lookupLmrReduction(@intCast(depth), @intCast(i)) else 0;
                const base_depth = depth - 1;
                const reduced_depth = if (reduction > 0) @max(@as(usize, 1), base_depth -| reduction) else base_depth;

                score = -(try negamax(self, position, -a - 1, -a, reduced_depth, ply + 1, false, false, false));

                if (score > a and reduction > 0) {
                    score = -(try negamax(self, position, -a - 1, -a, base_depth, ply + 1, false, false, false));
                }

                if (score > a and is_pv and score < beta) {
                    score = -(try negamax(self, position, -beta, -a, depth - 1, ply + 1, false, false, true));
                }
            }

            self.popRepetition();
            try position.unmakeMove(sm.move);

            if (score >= beta) {
                self.tt.set(position.hash, .{
                    .score = scoreToTT(score, ply),
                    .hash = position.hash,
                    .hash_move = sm.move,
                    .depth = @intCast(depth),
                    .node_type = .LOWERBOUND,
                });

                if (@intFromEnum(sm.move.flags) & @intFromEnum(MoveFlags.CAPTURE) == 0) {
                    // Set Killers
                    if (self.killers[ply][0].toU16() != sm.move.toU16()) {
                        self.killers[ply][1] = self.killers[ply][0];
                        self.killers[ply][0] = sm.move;
                    }

                    // Set History
                    const color = @intFromEnum(position.board_state.side_to_move);
                    self.history[color][sm.move.from_sq][sm.move.to_sq] += @as(i32, @intCast(depth * depth));
                }
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
            .score = scoreToTT(max, ply),
            .hash = position.hash,
            .hash_move = best_move.?,
            .depth = @intCast(depth),
            .node_type = node_type,
        });

        return max;
    }

    fn quiescenceSearch(self: *Searcher, position: *Position, alpha_: i32, beta: i32, ply: usize) !i32 {
        self.nodes += 1;
        if (self.nodes & 4095 == 0 and self.shouldStop() and self.depth_completed >= 1) {
            return error.SearchStopped;
        }

        // Check 3fold repetition
        if (self.isDrawByRepetitionOrRule50(position)) {
            return 0;
        }

        // TT probe
        const tt_entry = self.tt.get(position.hash);
        const hash_move: ?Move = if (tt_entry.hash == position.hash and tt_entry.node_type != .NONE) tt_entry.hash_move else null;

        if (tt_entry.hash == position.hash) {
            const adjusted = scoreFromTT(tt_entry.score, ply);
            switch (tt_entry.node_type) {
                .EXACT => return adjusted,
                .LOWERBOUND => if (adjusted >= beta) return adjusted,
                .UPPERBOUND => if (adjusted <= alpha_) return adjusted,
                .NONE => {},
            }
        }

        const static_eval = eval(position);
        if (static_eval >= beta) return static_eval;

        var delta: i32 = 1_000;

        const pawns_tobe_queen = position.bbs[@intFromEnum(PieceType.Pawn) + @as(usize, if (position.board_state.side_to_move == .Black) 6 else 0)] & utils.relativeRank(6, position.board_state.side_to_move);
        if (pawns_tobe_queen != 0) {
            delta += 775;
        }

        if (static_eval < alpha_ - delta) {
            return alpha_;
        }

        var alpha: i32 = if (static_eval > alpha_) static_eval else alpha_;

        const move_list_ptr = &self.move_lists[ply];
        try position.generateCaptureMoves(move_list_ptr);
        scoreMoves(position, self, ply, move_list_ptr, hash_move);

        var max = static_eval;
        var i: usize = 0;
        loop: while (i < move_list_ptr.count) : (i += 1) {
            const sm = move_list_ptr.pickNext(i);

            // SEE Pruning
            if (sm.score < 1_000_000) break;

            // Delta Pruning
            if (@intFromEnum(sm.move.flags) & @intFromEnum(MoveFlags.CAPTURE) != 0) {
                const per_move_delta: i32 = 200;
                const captured_piece_sq = blk: {
                    if (sm.move.flags != .EP_CAPTURE) break :blk sm.move.to_sq;
                    if (position.board_state.side_to_move == .White) break :blk sm.move.to_sq - 8;
                    break :blk sm.move.to_sq + 8;
                };
                const captured_piece = position.pieceAt(captured_piece_sq);

                const piece_value = movepick.PIECE_VALUES[@intFromEnum(captured_piece.?)];
                const prom_gain = switch (sm.move.flags) {
                    .KNIGHT_PROMOTION_CAPTURE => movepick.PIECE_VALUES[@intFromEnum(PieceType.Knight)] - movepick.PIECE_VALUES[@intFromEnum(PieceType.Pawn)],
                    .BISHOP_PROMOTION_CAPTURE => movepick.PIECE_VALUES[@intFromEnum(PieceType.Bishop)] - movepick.PIECE_VALUES[@intFromEnum(PieceType.Pawn)],
                    .ROOK_PROMOTION_CAPTURE => movepick.PIECE_VALUES[@intFromEnum(PieceType.Rook)] - movepick.PIECE_VALUES[@intFromEnum(PieceType.Pawn)],
                    .QUEEN_PROMOTION_CAPTURE => movepick.PIECE_VALUES[@intFromEnum(PieceType.Queen)] - movepick.PIECE_VALUES[@intFromEnum(PieceType.Pawn)],
                    else => 0,
                };
                if (static_eval + piece_value + prom_gain + per_move_delta < alpha) continue :loop;
            }

            try position.makeMove(sm.move);
            self.pushRepetition(position.hash);
            const score = -(try quiescenceSearch(self, position, -beta, -alpha, ply + 1));
            self.popRepetition();
            try position.unmakeMove(sm.move);
            if (score >= beta) return score;
            if (score > max) max = score;
            if (score > alpha) alpha = score;
        }
        return max;
    }

    fn shouldStop(self: *Searcher) bool {
        const time_stop: bool = blk: {
            if (self.move_time_millis == 0) break :blk false;
            const elapsed_ns = self.timer.?.durationTo(std.Io.Clock.now(.awake, self.io)).toNanoseconds();
            const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);
            break :blk elapsed_ms >= self.move_time_millis;
        };
        return self.should_stop or time_stop;
    }

    fn computeBudget(_: *Searcher, limits: SearchLimits, side: utils.Color) ?u64 {
        if (limits.infinite) return null; // no time limit
        if (limits.movetime_ms) |t| return t;

        const time_left = if (side == .White) limits.wtime_ms else limits.btime_ms;
        const inc = if (side == .White) limits.winc_ms else limits.binc_ms;

        if (time_left) |t| {
            const base = t / 30;
            return base + (inc orelse 0);
        }
        return null;
    }
};
