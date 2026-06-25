const std = @import("std");
const attacks = @import("attacks.zig");
const utils = @import("utils.zig");

const BISHOP_TABLE_SIZE: usize = 5248;
const ROOK_TABLE_SIZE: usize = 102400;

var bishop_table: [BISHOP_TABLE_SIZE]u64 = undefined;
var bishop_offsets: [64]u64 = undefined;
var rook_table: [ROOK_TABLE_SIZE]u64 = undefined;
var rook_offsets: [64]u64 = undefined;

var bishop_masks: [64]u64 = undefined;
var rook_masks: [64]u64 = undefined;
var knight_masks: [64]u64 = undefined;
var king_masks: [64]u64 = undefined;
var white_pawns_masks: [64]u64 = undefined;
var black_pawns_masks: [64]u64 = undefined;

var squares_between: [64][64]u64 = undefined;

var lmr: [64][64]usize = undefined;

pub fn lookupPawnAttacks(sq: u6, color: utils.Color) utils.Bitboard {
    return switch (color) {
        utils.Color.White => white_pawns_masks[@intCast(sq)],
        utils.Color.Black => black_pawns_masks[@intCast(sq)],
    };
}

pub fn lookupKnightAttacks(sq: u6) utils.Bitboard {
    return knight_masks[@intCast(sq)];
}

pub fn lookupKingAttacks(sq: u6) utils.Bitboard {
    return king_masks[@intCast(sq)];
}

pub fn lookupBishopAttacks(sq: u6, occupancy: utils.Bitboard) utils.Bitboard {
    const index = utils.pext(occupancy, bishop_masks[@intCast(sq)]);
    const offset = bishop_offsets[@intCast(sq)];
    return bishop_table[offset + index];
}

pub fn lookupRookAttacks(sq: u6, occupancy: utils.Bitboard) utils.Bitboard {
    const index = utils.pext(occupancy, rook_masks[@intCast(sq)]);
    const offset = rook_offsets[@intCast(sq)];
    return rook_table[offset + index];
}

pub fn lookupQueenAttacks(sq: u6, occupancy: utils.Bitboard) utils.Bitboard {
    return lookupBishopAttacks(sq, occupancy) | lookupRookAttacks(sq, occupancy);
}

pub fn lookupSquaresBetween(sq: u6, sq2: u6) utils.Bitboard {
    return squares_between[sq][sq2];
}

pub fn lookupLmrReduction(depth: u6, move_idx: u6) usize {
    return lmr[depth][move_idx];
}

pub fn initTables() void {
    var curr_bishop_offset: usize = 0;
    var curr_rook_offset: usize = 0;
    // bishop masks
    for (0..64) |sq| {
        const edges =
            ((utils.RANKS[0] | utils.RANKS[7]) & ~utils.maskRank(@intCast(sq))) |
            ((utils.FILES[0] | utils.FILES[7]) & ~utils.maskFile(@intCast(sq)));

        const piece_bb = @as(u64, 1) << @intCast(sq);

        // BISHOP MASKS
        const diag = utils.maskDiag(@intCast(sq));
        const anti_diag = utils.maskAntiDiag(@intCast(sq));
        const bishop_mask = (diag | anti_diag) & ~(edges) & ~(piece_bb);
        bishop_masks[sq] = bishop_mask;

        // BISHOP ATTACKS
        const relevant_bishop_bits = @popCount(bishop_mask);
        const bishop_table_size = @as(u64, 1) << @intCast(relevant_bishop_bits);
        bishop_offsets[sq] = curr_bishop_offset;
        var bishop_subset: u64 = 0;
        while (true) {
            const bishop_attacks = attacks.bishopAttacks(@intCast(sq), bishop_subset);
            const index = utils.pext(bishop_subset, bishop_mask);
            bishop_table[curr_bishop_offset + index] = bishop_attacks;
            bishop_subset = (bishop_subset -% bishop_mask) & bishop_mask;
            if (bishop_subset == 0) break;
        }
        curr_bishop_offset += bishop_table_size;

        // ROOK MASKS
        const rank = utils.maskRank(@intCast(sq));
        const file = utils.maskFile(@intCast(sq));
        const rook_mask = (rank | file) & ~(edges) & ~(piece_bb);
        rook_masks[sq] = rook_mask;

        // ROOK ATTACKS
        const relevant_rook_bits = @popCount(rook_mask);
        const rook_table_size = @as(u64, 1) << @intCast(relevant_rook_bits);
        rook_offsets[sq] = curr_rook_offset;
        var rook_subset: u64 = 0;
        while (true) {
            const rook_attacks = attacks.rookAttacks(@intCast(sq), rook_subset);
            const index = utils.pext(rook_subset, rook_mask);
            rook_table[curr_rook_offset + index] = rook_attacks;
            rook_subset = (rook_subset -% rook_mask) & rook_mask;
            if (rook_subset == 0) break;
        }
        curr_rook_offset += rook_table_size;

        knight_masks[sq] = attacks.knightAttacks(@intCast(sq));
        king_masks[sq] = attacks.kingAttacks(@intCast(sq));
        white_pawns_masks[sq] = attacks.pawnAttacks(@intCast(sq), utils.Color.White);
        black_pawns_masks[sq] = attacks.pawnAttacks(@intCast(sq), utils.Color.Black);

        // Mask squares between two squares
        for (0..64) |sq2| {
            const same_file = utils.maskFile(@intCast(sq)) & utils.maskFile(@intCast(sq2));
            const same_rank = utils.maskRank(@intCast(sq)) & utils.maskRank(@intCast(sq2));
            const same_diag = utils.maskDiag(@intCast(sq)) & utils.maskDiag(@intCast(sq2));
            const same_anti_diag = utils.maskAntiDiag(@intCast(sq)) & utils.maskAntiDiag(@intCast(sq2));
            const is_aligned = same_file | same_rank | same_diag | same_anti_diag != 0;

            if (sq2 == sq or !is_aligned) {
                squares_between[sq][sq2] = 0;
                continue;
            }

            const low: u6 = @intCast(@min(sq, sq2));
            const high: u6 = @intCast(@max(sq, sq2));
            const line: utils.Bitboard = if (same_file != 0) utils.maskFile(@intCast(sq)) else if (same_rank != 0) utils.maskRank(@intCast(sq)) else if (same_diag != 0) utils.maskDiag(@intCast(sq)) else if (same_anti_diag != 0) utils.maskAntiDiag(@intCast(sq)) else unreachable;
            squares_between[sq][sq2] = line & ((@as(u64, 1) << high) - 1) & ~((@as(u64, 1) << (low + 1)) - 1);
        }

        // Late move reduction
        for (0..64) |d| {
            inner: for (0..64) |i| {
                if (i == 0 or d == 0) {
                    lmr[d][i] = 0;
                    continue :inner;
                }
                lmr[d][i] = @intFromFloat(0.99 + @log(@as(f64, @floatFromInt(d))) * @log(@as(f64, @floatFromInt(i))) / 3.14);
            }
        }
    }
}
