const std = @import("std");
const attacks = @import("attacks.zig");
const utils = @import("utils.zig");
const magics = @import("magics.zig");
const builtin = @import("builtin");

pub const SliderMetadata = struct {
    mask: u64,
    offset: usize,

    // Magic exclusive fields
    magic: u64 = 0,
    shift: u6 = 0,
};

const has_bmi2 = builtin.cpu.has(.x86, .bmi2);

const BISHOP_TABLE_SIZE: usize = 5248;
const ROOK_TABLE_SIZE: usize = 102400;

pub const SLIDER_TABLE_SIZE: usize = BISHOP_TABLE_SIZE + ROOK_TABLE_SIZE;

var slider_metadata_table: [128]SliderMetadata = undefined;
var slider_table: [SLIDER_TABLE_SIZE]u64 = undefined;

var bishop_masks: [64]u64 = undefined;
var rook_masks: [64]u64 = undefined;
var knight_masks: [64]u64 = undefined;
var king_masks: [64]u64 = undefined;
var white_pawns_masks: [64]u64 = undefined;
var black_pawns_masks: [64]u64 = undefined;

var squares_between: [64][64]u64 = undefined;

var lmr: [64][256]usize = undefined;

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
    const metadata = slider_metadata_table[@intCast(sq)];
    const index = if (has_bmi2) utils.pext(occupancy, metadata.mask) else magics.calculateHashIdx(metadata.magic, occupancy & metadata.mask, metadata.shift);
    return slider_table[metadata.offset + index];
}

pub fn lookupRookAttacks(sq: u6, occupancy: utils.Bitboard) utils.Bitboard {
    const metadata = slider_metadata_table[@as(usize, sq) + 64];
    const index = if (has_bmi2) utils.pext(occupancy, metadata.mask) else magics.calculateHashIdx(metadata.magic, occupancy & metadata.mask, metadata.shift);
    return slider_table[metadata.offset + index];
}

pub fn lookupQueenAttacks(sq: u6, occupancy: utils.Bitboard) utils.Bitboard {
    return lookupBishopAttacks(sq, occupancy) | lookupRookAttacks(sq, occupancy);
}

pub fn lookupSquaresBetween(sq: u6, sq2: u6) utils.Bitboard {
    return squares_between[sq][sq2];
}

pub fn lookupLmrReduction(depth: usize, move_idx: usize) usize {
    return lmr[@min(depth, lmr.len - 1)][@min(move_idx, lmr[0].len - 1)];
}

pub fn initTables() void {
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

        // ROOK MASKS
        const rank = utils.maskRank(@intCast(sq));
        const file = utils.maskFile(@intCast(sq));
        const rook_mask = (rank | file) & ~(edges) & ~(piece_bb);
        rook_masks[sq] = rook_mask;

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
            inner: for (0..256) |i| {
                if (i == 0 or d == 0) {
                    lmr[d][i] = 0;
                    continue :inner;
                }
                const depth = @min(d, 63);
                lmr[d][i] = @intFromFloat(0.99 + @log(@as(f64, @floatFromInt(depth))) * @log(@as(f64, @floatFromInt(i))) / 3.14);
            }
        }
    }

    if (has_bmi2) {
        initSliderTablesForPEXT();
    } else {
        initSliderTablesForMagic();
    }
}

fn initSliderTablesForPEXT() void {
    var offset: usize = 0;
    for (0..64) |sq| {
        // BISHOP ATTACKS
        const bishop_mask = bishop_masks[sq];
        const relevant_bishop_bits = @popCount(bishop_mask);
        const bishop_table_size = @as(u64, 1) << @intCast(relevant_bishop_bits);
        var bishop_subset: u64 = 0;
        while (true) {
            const bishop_attacks = attacks.bishopAttacks(@intCast(sq), bishop_subset);
            const index = utils.pext(bishop_subset, bishop_mask);
            slider_table[offset + index] = bishop_attacks;
            slider_metadata_table[sq] = .{ .mask = bishop_mask, .offset = offset };

            bishop_subset = (bishop_subset -% bishop_mask) & bishop_mask;
            if (bishop_subset == 0) break;
        }
        offset += bishop_table_size;

        const rook_mask = rook_masks[sq];
        // ROOK ATTACKS
        const relevant_rook_bits = @popCount(rook_mask);
        const rook_table_size = @as(u64, 1) << @intCast(relevant_rook_bits);
        var rook_subset: u64 = 0;
        while (true) {
            const rook_attacks = attacks.rookAttacks(@intCast(sq), rook_subset);
            const index = utils.pext(rook_subset, rook_mask);
            slider_table[offset + index] = rook_attacks;
            slider_metadata_table[64 + sq] = .{ .mask = rook_mask, .offset = offset };

            rook_subset = (rook_subset -% rook_mask) & rook_mask;
            if (rook_subset == 0) break;
        }
        offset += rook_table_size;
    }
}

fn initSliderTablesForMagic() void {
    var offset: usize = 0;

    for (0..64) |sq| {
        const bishop_magic = magics.initMagic(@intCast(sq), true, &offset, &slider_table);
        slider_metadata_table[sq] = bishop_magic;

        const rook_magic = magics.initMagic(@intCast(sq), false, &offset, &slider_table);
        slider_metadata_table[sq + 64] = rook_magic;
    }
}
