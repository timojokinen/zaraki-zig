const std = @import("std");
const Position = @import("position.zig").Position;
const Move = @import("move.zig").Move;
const eval = @import("eval.zig").eval;
const Color = @import("utils.zig").Color;

const INF: i32 = 32_000;

pub fn search(position: *Position, depth: usize) !Move {
    var move_list: [256]Move = undefined;
    const move_count = try position.generateMoves(&move_list);
    
    var best_move: Move = move_list[0];
    var best_score: i32 = -INF;

    for (0..move_count) |idx| {
        const move = move_list[idx];
        try position.makeMove(move);
        const score = -(try negamax(position, -INF, INF, depth - 1));
        try position.unmakeMove(move);
        if (score > best_score) {
            best_score = score;
            best_move = move;
        }
    }
    return best_move;
}

fn negamax(position: *Position, alpha: i32, beta: i32, depth: usize) !i32 {
    if (depth == 0) return eval(position);
    var move_list: [256]Move = undefined;
    const move_count = try position.generateMoves(&move_list);

    // TODO: Handle stalemate (should be 0, not -INF)
    if (move_count == 0) return -INF;
    
    var max: i32 = -INF;
    var a = alpha;

    for (move_list[0..move_count]) |move| {
        try position.makeMove(move);
        const score = -(try negamax(position, -beta, -a, depth - 1));
        try position.unmakeMove(move);

        if (score > max) {
            max = score;
            if (score > a) {
                a = score;
            }
        }

        if (score >= beta) {
            return max;
        }
    }

    return max;
}

fn quiescenceSearch(position: *Position, alpha_: i32, beta: i32) !i32 {
    const static_eval: i32 = eval(position);
    var alpha: i32 = alpha_;

    var move_list: [256]Move = undefined;
    const move_count = try position.generateMoves(&move_list);
    const qmove_count = filterCaptures(move_list[0..move_count]);

    var max: i32 = static_eval;
    if (max >= beta) return max;
    if (max > alpha) alpha = max;


    for (move_list[0..qmove_count]) |move| {
        try position.makeMove(move);
        const score = -quiescenceSearch(position, -beta, -alpha);
        try position.unmakeMove(move);

        if (score >= beta) return score;
        if (score > max) max = score;
        if (score > alpha) alpha = score;
    }

    // TODO: maybe don't stop if king is in check

    return max;

}

fn filterCaptures(moves: []Move) usize {
    var w: usize = 0;
    for (moves) |move| {
        const is_capture = move.flags & 0b0100 != 0;
        const is_promotion = move.flags & 0b1000 != 0;
        if (is_capture or is_promotion) {
            moves[w] = move;
            w += 1;
        }
    }
    return w;
}
