const std = @import("std");
const mv = @import("move.zig");
const eval = @import("eval.zig").eval;
const utils = @import("utils.zig");
const tt = @import("tt.zig");
const tables = @import("tables.zig");
const movepick = @import("movepick.zig");
const zobrist = @import("zobrist.zig");

const PieceType = @import("piece.zig").PieceType;
const Position = @import("position.zig").Position;

const INF: i32 = 32_000;
const MAX_SEARCH_PLY: usize = 128;
const MAX_GAME_PLY: usize = 1024;
const MAX_HASH_HISTORY: usize = MAX_SEARCH_PLY + MAX_GAME_PLY;
const MATE: i32 = 31_000;
const MATE_THRESHOLD: i32 = MATE - @as(i32, MAX_SEARCH_PLY);

const REP_TABLE_BITS = 12;
const REP_TABLE_SIZE = 1 << REP_TABLE_BITS;
const REP_TABLE_MASK = REP_TABLE_SIZE - 1;

pub var tt_enable = true;
pub var tt_enable_replacement_strategy = true;
pub var tt_enable_cutoff = true;
pub var tt_enable_move_ordering = true;

fn scoreToTT(score: i32, ply: usize) i16 {
    var s: i32 = score;
    if (score > MATE_THRESHOLD) s = score + @as(i32, @intCast(ply));
    if (score < -MATE_THRESHOLD) s = score - @as(i32, @intCast(ply));

    return @intCast(std.math.clamp(s, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn scoreFromTT(score: i16, ply: usize) i32 {
    if (score > MATE_THRESHOLD) return score - @as(i16, @intCast(ply));
    if (score < -MATE_THRESHOLD) return score + @as(i16, @intCast(ply));
    return @intCast(score);
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

pub const SearchStats = struct {
    tt_probes: usize = 0,
    tt_hits: usize = 0, // Hash matches
    tt_usable: usize = 0, // Hash matches and depth >= current_depth
    tt_cutoffs_exact: usize = 0,
    tt_cutoffs_lower: usize = 0,
    tt_cutoffs_upper: usize = 0,
    tt_move_used: usize = 0,
    tt_stores: usize = 0,
};

pub const TimeBudget = struct {
    hard_cap_ms: u64,
    soft_cap_ms: ?u64,
};

pub const Searcher = struct {
    tt: *tt.TranspositionTable,
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: ?*std.Io.Writer = null,

    pv: [MAX_SEARCH_PLY][MAX_SEARCH_PLY]mv.Move = std.mem.zeroes([MAX_SEARCH_PLY][MAX_SEARCH_PLY]mv.Move),
    pv_length: [MAX_SEARCH_PLY]u8 = [_]u8{0} ** MAX_SEARCH_PLY,

    saved_pv: [MAX_SEARCH_PLY]mv.Move = undefined,
    saved_pv_length: usize = 0,

    move_lists: [MAX_SEARCH_PLY]mv.MoveList = std.mem.zeroes([MAX_SEARCH_PLY]mv.MoveList),
    nodes: usize = 0,

    history: [2][64][64]i32 = undefined,
    killers: [MAX_SEARCH_PLY][2]mv.Move = undefined,

    should_stop: bool = false,
    move_time_millis: ?u64 = null,
    timer: ?std.Io.Timestamp = null,

    best_move_so_far: ?mv.Move = null,
    depth_completed: usize = 0,
    seldepth: usize = 0,

    hash_history: [MAX_HASH_HISTORY]u64 = std.mem.zeroes([MAX_HASH_HISTORY]u64),
    hash_history_length: usize = 0,
    repetition_table: [4096]u16 = [_]u16{0} ** REP_TABLE_SIZE,

    stats: SearchStats = .{},

    gen: u4 = 0,

    pub fn resetPerSearch(self: *Searcher) void {
        self.nodes = 0;
        self.should_stop = false;
        self.saved_pv_length = 0;
        self.pv_length = [_]u8{0} ** MAX_SEARCH_PLY;
        self.pv = std.mem.zeroes([MAX_SEARCH_PLY][MAX_SEARCH_PLY]mv.Move);
        self.killers = std.mem.zeroes([MAX_SEARCH_PLY][2]mv.Move);
        self.history = std.mem.zeroes([2][64][64]i32);
        self.stats = .{};
        self.best_move_so_far = null;
        self.depth_completed = 0;
        self.seldepth = 0;
        self.move_time_millis = null;
    }

    pub fn resetPerGame(self: *Searcher) void {
        self.resetPerSearch();
        self.tt.clear();
        self.resetPerNewPosition();
        self.gen = 0;
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

    fn makeMoveWithDiagnostics(position: *Position, move: mv.Move, ply: usize, phase: []const u8, remaining_depth: ?usize) !void {
        position.makeMove(move) catch |err| {
            std.debug.print(
                "search makeMove failed: error={s} phase={s} ply={} remaining_depth={any} move={s}{s} flags={s} side={s} hash=0x{x} board_state={any} bbs={any}\n",
                .{
                    @errorName(err),
                    phase,
                    ply,
                    remaining_depth,
                    utils.idx2san(move.from_sq),
                    utils.idx2san(move.to_sq),
                    @tagName(move.flags),
                    @tagName(position.board_state.side_to_move),
                    position.hash,
                    position.board_state,
                    position.bbs,
                },
            );
            return err;
        };
    }

    pub fn think(self: *Searcher, position: *Position, search_limits: SearchLimits) !mv.Move {
        const root_position = position.*;
        defer position.* = root_position;

        const depth = search_limits.depth orelse 99;
        if (depth == 0) return error.InvalidDepth;
        self.resetPerSearch();

        const budget = self.computeBudget(position, search_limits);
        self.move_time_millis = if (budget) |b| b.hard_cap_ms else null;
        const soft_cap = if (budget) |b| b.soft_cap_ms else null;

        self.gen = (self.gen + 1) & 15;
        self.timer = std.Io.Clock.now(.awake, self.io);

        var root_moves = mv.MoveList{};
        try position.generateMoves(&root_moves);
        if (root_moves.count == 0) return error.NoLegalMoves;
        self.best_move_so_far = root_moves.moves[0].move;

        var d: usize = 1;
        var prev_score: i32 = 0;
        outer: while (d <= depth) : (d += 1) {
            var delta: i32 = 25;
            var alpha = if (d >= 4) prev_score - delta else -INF;
            var beta = if (d >= 4) prev_score + delta else INF;

            inner: while (true) {
                const score = negamax(self, position, alpha, beta, d, 0, true, false, true) catch |err| switch (err) {
                    SearcherError.SearchStopped => {
                        break :outer;
                    },
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

            if (self.stdout) |out| {
                try out.print("info depth {} seldepth {} nodes {} time {} nps {}\n", .{
                    d, self.seldepth, self.nodes, elapsed_ms, nps,
                });
                try out.print("info score cp {}\n", .{prev_score});
                try out.print("info tt_probes {} tt_hits {} tt_usable {} tt_cutoffs {} tt_cutoffs_exact {} tt_cutoffs_lower {} tt_cutoffs_upper {} tt_move_used {} tt_stores {} \n", .{ self.stats.tt_probes, self.stats.tt_hits, self.stats.tt_usable, self.stats.tt_cutoffs_exact + self.stats.tt_cutoffs_lower + self.stats.tt_cutoffs_upper, self.stats.tt_cutoffs_exact, self.stats.tt_cutoffs_lower, self.stats.tt_cutoffs_upper, self.stats.tt_move_used, self.stats.tt_stores });
                try out.writeAll("\n");
                try out.flush();
            }

            self.depth_completed = d;

            if (soft_cap) |sc| {
                if (elapsed_ms >= sc) return self.best_move_so_far orelse self.pv[0][0];
            }
        }

        return self.best_move_so_far orelse self.pv[0][0];
    }

    fn negamax(self: *Searcher, position: *Position, alpha: i32, beta: i32, _depth: usize, ply: usize, is_root: bool, is_null: bool, is_pv: bool) !i32 {
        self.seldepth = @max(self.seldepth, ply);
        self.pv_length[ply] = 0;
        var depth: usize = _depth;

        if (depth == 0) return quiescenceSearch(self, position, alpha, beta, ply);

        self.nodes += 1;

        if (self.nodes & 1023 == 0 and self.shouldStop()) {
            return error.SearchStopped;
        }

        // Check 3fold repetition
        if (self.isDrawByRepetitionOrRule50(position)) {
            return 0;
        }

        // TT-Probe
        if (tt_enable) self.stats.tt_probes += 1;
        const tt_entry = self.tt.get(position.hash);
        if (tt_entry.node_type != .NONE) self.stats.tt_hits += 1;

        const hash_move: ?mv.Move = if (tt_entry.node_type != .NONE and tt_entry.node_type != .UPPERBOUND and tt_enable and tt_enable_move_ordering) tt_entry.hash_move else null;
        if (tt_entry.depth >= @as(u8, @intCast(depth)) and !is_root and tt_enable and tt_enable_cutoff) {
            self.stats.tt_usable += 1;
            const adjusted_score = scoreFromTT(tt_entry.score, ply);
            if (tt_entry.node_type == .EXACT) {
                // We know the exact score of this position from a deep enough search.
                self.stats.tt_cutoffs_exact += 1;
                return adjusted_score;
            }

            if (tt_entry.node_type == .LOWERBOUND) {
                // The score is at least this high. If it reaches beta, this position is already too good for the opponent to allow.
                if (adjusted_score >= beta) {
                    self.stats.tt_cutoffs_lower += 1;
                    return adjusted_score;
                }
            }

            if (tt_entry.node_type == .UPPERBOUND) {
                // The score is at most this high. If it does not reach alpha, this position is already too bad to improve our line.
                if (adjusted_score <= alpha) {
                    self.stats.tt_cutoffs_upper += 1;
                    return adjusted_score;
                }
            }
        }

        const move_list_ptr = &self.move_lists[ply];
        try position.generateMoves(move_list_ptr);
        movepick.scoreMoves(position, self, ply, move_list_ptr, hash_move);

        if (move_list_ptr.count == 0) {
            if (!position.inCheck()) return 0; // Stalemate
            return -MATE + @as(i32, @intCast(ply));
        }

        const in_check = position.inCheck();

        if (in_check) depth += 1;

        // Null-Move-Pruning
        const color_offset: usize = if (position.board_state.side_to_move == .Black) 6 else 0;
        const non_king_pawns = (position.bbs[@intFromEnum(PieceType.Bishop) + color_offset] | position.bbs[@intFromEnum(PieceType.Knight) + color_offset] | position.bbs[@intFromEnum(PieceType.Rook) + color_offset] | position.bbs[@intFromEnum(PieceType.Queen) + color_offset]) != 0;
        if (!is_null and !is_root and !position.inCheck() and non_king_pawns and depth >= 3) {
            var R: usize = 2 + @divTrunc(depth, 6);
            R = @min(R, depth);
            position.makeNullMove();
            errdefer position.unmakeNullMove();
            const score = -(try negamax(self, position, -beta, -(beta - 1), depth - R, ply + 1, false, true, false));
            position.unmakeNullMove();

            if (score >= beta) {
                return score;
            }
        }

        // Search Loop
        var max: i32 = -INF;
        var a = alpha;
        var best_move: ?mv.Move = null;

        var i: usize = 0;
        while (i < move_list_ptr.count) : (i += 1) {
            const sm = move_list_ptr.pickNext(i);

            if (hash_move) |hm| {
                if (i == 0 and sm.move.toU16() == hm.toU16()) self.stats.tt_move_used += 1;
            }

            try makeMoveWithDiagnostics(position, sm.move, ply, "negamax", depth);
            errdefer position.unmakeMove(sm.move);
            self.pushRepetition(position.hash);
            errdefer self.popRepetition();

            const child_is_pv = i == 0 and is_pv;

            var score: i32 = undefined;

            if (child_is_pv) {
                score = -(try negamax(self, position, -beta, -a, depth - 1, ply + 1, false, false, true));
            } else {
                const flags_int = @intFromEnum(sm.move.flags);
                const is_quiet = (flags_int & 0b1100) == 0;
                const do_lmr = depth >= 3 and i >= 3 and !position.inCheck() and !in_check and is_quiet;
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
            position.unmakeMove(sm.move);

            if (score >= beta) {
                if (tt_enable) {
                    self.stats.tt_stores += 1;
                    self.tt.set(position.hash, .{
                        .score = scoreToTT(score, ply),
                        .hash = position.hash,
                        .hash_move = sm.move,
                        .depth = @intCast(depth),
                        .node_type = .LOWERBOUND,
                        .age = self.gen,
                    });
                }

                if (@intFromEnum(sm.move.flags) & @intFromEnum(mv.MoveFlags.CAPTURE) == 0) {
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

        const node_type: tt.NodeType = if (max > alpha) .EXACT else .UPPERBOUND;
        if (tt_enable) {
            self.stats.tt_stores += 1;
            self.tt.set(position.hash, .{
                .score = scoreToTT(max, ply),
                .hash = position.hash,
                .hash_move = best_move.?,
                .depth = @intCast(depth),
                .node_type = node_type,
                .age = self.gen,
            });
        }

        return max;
    }

    fn quiescenceSearch(self: *Searcher, position: *Position, alpha_: i32, beta: i32, ply: usize) !i32 {
        self.seldepth = @max(self.seldepth, ply);
        self.nodes += 1;
        if (self.nodes & 1023 == 0 and self.shouldStop()) {
            return error.SearchStopped;
        }

        // Check 3fold repetition
        if (self.isDrawByRepetitionOrRule50(position)) {
            return 0;
        }

        // TT probe
        if (tt_enable) self.stats.tt_probes += 1;
        const tt_entry = self.tt.get(position.hash);
        if (tt_entry.node_type != .NONE) self.stats.tt_hits += 1;
        const hash_move: ?mv.Move = if (tt_entry.hash == position.hash and tt_entry.node_type != .NONE and tt_enable and tt_enable_move_ordering) tt_entry.hash_move else null;

        if (tt_entry.node_type != .NONE and tt_enable and tt_enable_cutoff) {
            self.stats.tt_usable += 1;
            const adjusted = scoreFromTT(tt_entry.score, ply);
            switch (tt_entry.node_type) {
                .EXACT => {
                    self.stats.tt_cutoffs_exact += 1;
                    return adjusted;
                },
                .LOWERBOUND => if (adjusted >= beta) {
                    self.stats.tt_cutoffs_lower += 1;
                    return adjusted;
                },
                .UPPERBOUND => if (adjusted <= alpha_) {
                    self.stats.tt_cutoffs_upper += 1;
                    return adjusted;
                },
                .NONE => {},
            }
        }

        const in_check = position.inCheck();

        const static_eval = eval(position);

        var alpha: i32 = alpha_;

        if (!in_check) {
            if (static_eval >= beta) return static_eval;

            var delta: i32 = 1_000;

            const pawns_tobe_queen = position.bbs[@intFromEnum(PieceType.Pawn) + @as(usize, if (position.board_state.side_to_move == .Black) 6 else 0)] & utils.relativeRank(6, position.board_state.side_to_move);
            if (pawns_tobe_queen != 0) {
                delta += 775;
            }

            if (static_eval < (alpha_ - delta)) {
                return alpha_;
            }

            alpha = if (static_eval > alpha_) static_eval else alpha_;
        }

        const move_list_ptr = &self.move_lists[ply];
        if (in_check) try position.generateMoves(move_list_ptr) else try position.generateCaptureMoves(move_list_ptr);

        if (in_check and move_list_ptr.count == 0)
            return -MATE + @as(i32, @intCast(ply));

        movepick.scoreMoves(position, self, ply, move_list_ptr, hash_move);

        var max = if (in_check) -INF else static_eval;
        var i: usize = 0;
        loop: while (i < move_list_ptr.count) : (i += 1) {
            const sm = move_list_ptr.pickNext(i);

            if (hash_move) |hm| {
                if (i == 0 and sm.move.toU16() == hm.toU16()) self.stats.tt_move_used += 1;
            }
            // SEE Pruning
            if (sm.score < 1_000_000 and !in_check) break;

            // Delta Pruning
            if (@intFromEnum(sm.move.flags) & @intFromEnum(mv.MoveFlags.CAPTURE) != 0 and !in_check) {
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

            try makeMoveWithDiagnostics(position, sm.move, ply, "quiescence", null);
            errdefer position.unmakeMove(sm.move);
            self.pushRepetition(position.hash);
            errdefer self.popRepetition();
            const score = -(try quiescenceSearch(self, position, -beta, -alpha, ply + 1));
            self.popRepetition();
            position.unmakeMove(sm.move);
            if (score >= beta) return score;
            if (score > max) max = score;
            if (score > alpha) alpha = score;
        }
        return max;
    }

    fn shouldStop(self: *Searcher) bool {
        if (self.should_stop) return true;

        const hard_cap = self.move_time_millis orelse return false;
        const elapsed_ns = self.timer.?.durationTo(
            std.Io.Clock.now(.awake, self.io),
        ).toNanoseconds();
        const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);
        return elapsed_ms >= hard_cap;
    }

    fn computeBudget(_: *Searcher, pos: *Position, limits: SearchLimits) ?TimeBudget {
        if (limits.infinite) return null; // no time limit
        //
        const safety: u64 = 30;
        if (limits.movetime_ms) |t| return .{ .hard_cap_ms = @max(t -| safety, 1), .soft_cap_ms = null };

        const side = pos.board_state.side_to_move;
        const time_left = if (side == .White) limits.wtime_ms else limits.btime_ms;
        const inc = (if (side == .White) limits.winc_ms else limits.binc_ms) orelse 0;

        if (time_left) |t| {
            const move_number: u64 = pos.board_state.fullmove_number;
            const remaining_moves: u64 = @max(10, 40 -| move_number);

            const raw_soft = (t / remaining_moves) +| (inc / 2);
            const absolute_ceiling = @max(t -| safety, 1);
            const strategic_cap =
                @max(@min(t / 5, absolute_ceiling), 1);

            const hard = @max(
                @min(raw_soft *| 2, strategic_cap),
                1,
            );
            const soft = @min(@max(raw_soft, 1), hard);

            return .{
                .hard_cap_ms = hard,
                .soft_cap_ms = soft,
            };
        }
        return null;
    }
};

test "TranspositionTable Node Count" {
    tables.initTables();
    zobrist.initZobristKeys();

    const positions: [7][]const u8 = .{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    };

    const tt_size: usize = 1 << 16;

    var node_count_no_tt: usize = 0;
    var node_count_full_tt: usize = 0;
    var node_count_cutoff_only: usize = 0;
    var node_count_move_ordering_only: usize = 0;

    for (0..positions.len) |pos_idx| {
        const search_limits: SearchLimits = .{ .depth = 10 };
        {
            tt_enable = false;
            tt_enable_cutoff = false;
            tt_enable_move_ordering = false;

            var tt1 = try tt.TranspositionTable.init(std.testing.allocator, tt_size);
            defer tt1.deinit();
            var searcher: Searcher = .{ .io = std.testing.io, .allocator = std.testing.allocator, .tt = &tt1 };
            var pos = try Position.createFromFen(positions[pos_idx]);

            _ = try searcher.think(&pos, search_limits);
            std.debug.print("Nodes no tt {}\n", .{searcher.nodes});
            node_count_no_tt += searcher.nodes;
            tt1.clear();
        }

        {
            tt_enable = true;
            tt_enable_cutoff = false;
            tt_enable_move_ordering = true;

            var tt2 = try tt.TranspositionTable.init(std.testing.allocator, tt_size);
            defer tt2.deinit();
            var searcher: Searcher = .{ .io = std.testing.io, .allocator = std.testing.allocator, .tt = &tt2 };
            var pos = try Position.createFromFen(positions[pos_idx]);

            _ = try searcher.think(&pos, search_limits);
            std.debug.print("Nodes move ordering {}\n", .{searcher.nodes});
            node_count_move_ordering_only += searcher.nodes;
            tt2.clear();
        }

        {
            tt_enable = true;
            tt_enable_cutoff = true;
            tt_enable_move_ordering = false;

            var tt3 = try tt.TranspositionTable.init(std.testing.allocator, tt_size);
            defer tt3.deinit();
            var searcher: Searcher = .{ .io = std.testing.io, .allocator = std.testing.allocator, .tt = &tt3 };
            var pos = try Position.createFromFen(positions[pos_idx]);

            _ = try searcher.think(&pos, search_limits);
            std.debug.print("Nodes cutoff {}\n", .{searcher.nodes});
            node_count_cutoff_only += searcher.nodes;
            tt3.clear();
        }

        {
            tt_enable = true;
            tt_enable_cutoff = true;
            tt_enable_move_ordering = true;

            var tt4 = try tt.TranspositionTable.init(std.testing.allocator, tt_size);
            defer tt4.deinit();
            var searcher: Searcher = .{ .io = std.testing.io, .allocator = std.testing.allocator, .tt = &tt4 };
            var pos = try Position.createFromFen(positions[pos_idx]);

            _ = try searcher.think(&pos, search_limits);
            std.debug.print("Nodes full {}\n", .{searcher.nodes});
            node_count_full_tt += searcher.nodes;
            tt4.clear();
            std.debug.print("\n", .{});
        }
    }

    std.debug.print(
        \\no tt:       {}
        \\full tt:     {}
        \\cutoff only: {}
        \\move only:   {}
        \\
    , .{
        node_count_no_tt,
        node_count_full_tt,
        node_count_cutoff_only,
        node_count_move_ordering_only,
    });

    try std.testing.expect(node_count_no_tt > node_count_full_tt);
    try std.testing.expect(node_count_move_ordering_only > node_count_full_tt);
    try std.testing.expect(node_count_cutoff_only > node_count_full_tt);
}
