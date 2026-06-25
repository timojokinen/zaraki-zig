const Position = @import("position.zig").Position;
const std = @import("std");
const PieceType = @import("piece.zig").PieceType;
const Move = @import("move.zig").Move;
const MoveFlags = @import("move.zig").MoveFlags;
const MoveList = @import("move.zig").MoveList;
const Searcher = @import("search.zig").Searcher;
const tables = @import("tables.zig");
const Color = @import("utils.zig").Color;

pub fn scoreMoves(position: *Position, searcher: *Searcher, ply: usize, move_list: *MoveList, hash_move: ?Move) void {
    for (move_list.moves[0..move_list.count]) |*scored_move| {
        if (hash_move) |hm| {
            if (hm.toU16() == scored_move.move.toU16()) scored_move.score += 8_000_000;
        }

        const flags = @intFromEnum(scored_move.move.flags);

        if ((flags & @intFromEnum(MoveFlags.QUEEN_PROMOTION)) == @intFromEnum(MoveFlags.QUEEN_PROMOTION)) {
            scored_move.score += 1_000_000;
        }

        if (flags & @intFromEnum(MoveFlags.CAPTURE) != 0) {
            const is_ep = flags == @intFromEnum(MoveFlags.EP_CAPTURE);
            const ep_captured_sq: ?u6 = if (is_ep) blk: {
                const pawn_direction: i8 = if (position.board_state.side_to_move == .White) 1 else -1;
                const ep_target_i: i8 = @intCast(scored_move.move.to_sq);
                const captured_i: i8 = ep_target_i - 8 * pawn_direction;
                break :blk @intCast(captured_i);
            } else null;

            const prom_piece = switch (scored_move.move.flags) {
                .BISHOP_PROMOTION_CAPTURE, .BISHOP_PROMOTION => PieceType.Bishop,
                .ROOK_PROMOTION_CAPTURE, .ROOK_PROMOTION => PieceType.Rook,
                .QUEEN_PROMOTION_CAPTURE, .QUEEN_PROMOTION => PieceType.Queen,
                .KNIGHT_PROMOTION_CAPTURE, .KNIGHT_PROMOTION => PieceType.Knight,
                else => null,
            };

            const see_val = seeExact(
                position,
                scored_move.move.from_sq,
                scored_move.move.to_sq,
                if (is_ep) .Pawn else position.pieceAt(scored_move.move.to_sq).?,
                if (is_ep) ep_captured_sq.? else null,
                prom_piece,
                position.board_state.side_to_move,
            );

            const mvv_lva_score = scoreMVVLVA(position, scored_move.move);
            scored_move.score += mvv_lva_score;

            if (see_val >= 0) {
                scored_move.score += 1_000_000;
            }
        } else {
            if (searcher.killers[ply][0].toU16() == scored_move.move.toU16()) {
                scored_move.score += 600_000;
            } else if (searcher.killers[ply][1].toU16() == scored_move.move.toU16()) {
                scored_move.score += 500_000;
            } else {
                scored_move.score += searcher.history[@intFromEnum(position.board_state.side_to_move)][scored_move.move.from_sq][scored_move.move.to_sq];
            }
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

pub fn squareAttackers(bbs: *const [12]u64, occ: u64, to_sq: u6) u64 {
    var bb: u64 = 0;

    const queens = bbs[@intFromEnum(PieceType.Queen)] | bbs[@intFromEnum(PieceType.Queen) + 6];
    const bishops_queens = queens | bbs[@intFromEnum(PieceType.Bishop)] | bbs[@intFromEnum(PieceType.Bishop) + 6];
    const rook_queens = queens | bbs[@intFromEnum(PieceType.Rook)] | bbs[@intFromEnum(PieceType.Rook) + 6];
    const knights = bbs[@intFromEnum(PieceType.Knight)] | bbs[@intFromEnum(PieceType.Knight) + 6];
    const kings = bbs[@intFromEnum(PieceType.King)] | bbs[@intFromEnum(PieceType.King) + 6];

    bb |= tables.lookupPawnAttacks(to_sq, .White) & bbs[@intFromEnum(PieceType.Pawn) + 6];
    bb |= tables.lookupPawnAttacks(to_sq, .Black) & bbs[@intFromEnum(PieceType.Pawn)];
    bb |= tables.lookupKnightAttacks(to_sq) & knights;
    bb |= tables.lookupRookAttacks(to_sq, occ) & rook_queens;
    bb |= tables.lookupBishopAttacks(to_sq, occ) & bishops_queens;
    bb |= tables.lookupKingAttacks(to_sq) & kings;

    return bb;
}

pub const PIECE_VALUES: [6]i32 = .{ 100, 320, 330, 510, 1_000, 20_000 };

pub fn leastValuableAttacker(bbs: *const [12]u64, attdef: u64, color: Color) ?struct { PieceType, u6 } {
    for (0..6) |piece_idx| {
        const piece_idx_byside = piece_idx + @as(usize, if (color == .Black) 6 else 0);
        const subset: u64 = attdef & bbs[@intCast(piece_idx_byside)];
        if (subset > 0) return .{ @enumFromInt(piece_idx), @intCast(@ctz(subset)) };
    }
    return null;
}

// TODO: For move ordering use swap algorithm instead of exact see
pub fn seeExact(position: *Position, from_sq: u6, to_sq: u6, captured_piece: PieceType, en_passant_sq: ?u6, prom_piece: ?PieceType, side_to_move: Color) i32 {
    std.debug.assert((en_passant_sq != null and prom_piece != null) == false);

    var bbs: [12]u64 = position.bbs;
    var white_bbs: u64 = 0;
    var black_bbs: u64 = 0;

    inline for (0..6) |idx| {
        white_bbs |= bbs[@intCast(idx)];
        black_bbs |= bbs[@intCast(idx + 6)];
    }
    var occ = white_bbs | black_bbs;

    var d: usize = 0;
    var gain: [32]i32 = undefined;

    gain[0] = PIECE_VALUES[@intFromEnum(captured_piece)];
    if (prom_piece) |p_piece|
        gain[0] += PIECE_VALUES[@intFromEnum(p_piece)] - PIECE_VALUES[0];

    const moving_piece = position.pieceAt(from_sq).?;
    var victim = if (prom_piece) |p_piece| p_piece else moving_piece;

    occ &= ~(@as(u64, 1) << from_sq);
    bbs[@intFromEnum(moving_piece) + @as(usize, if (side_to_move == .Black) 6 else 0)] &= ~(@as(u64, 1) << from_sq);
    if (en_passant_sq) |ep_sq| {
        occ &= ~(@as(u64, 1) << ep_sq);
        bbs[@intFromEnum(captured_piece) + @as(usize, if (side_to_move == .Black) 0 else 6)] &= ~(@as(u64, 1) << ep_sq);
    } else {
        bbs[@intFromEnum(captured_piece) + @as(usize, if (side_to_move == .Black) 0 else 6)] &= ~(@as(u64, 1) << to_sq);
    }
    var attdef = squareAttackers(&bbs, occ, to_sq);

    var side = side_to_move.opp();

    while (true) {
        attdef &= occ;
        const opp_occ = (if (side == .Black) white_bbs else black_bbs) & occ;
        const attacker = leastValuableAttacker(&bbs, attdef, side) orelse break;
        const att_type, const att_sq = attacker;

        if (att_type == .King and (attdef & opp_occ) != 0) {
            break;
        }

        d += 1;
        occ &= ~(@as(u64, 1) << att_sq);
        bbs[@intFromEnum(att_type) + @as(usize, if (side == .Black) 6 else 0)] &= ~(@as(u64, 1) << att_sq);

        gain[d] = PIECE_VALUES[@intFromEnum(victim)] - gain[d - 1];
        victim = att_type;
        side = side.opp();

        const queens = bbs[@intFromEnum(PieceType.Queen)] | bbs[@intFromEnum(PieceType.Queen) + 6];
        const rook_queens = queens | bbs[@intFromEnum(PieceType.Rook)] | bbs[@intFromEnum(PieceType.Rook) + 6];
        const bishop_queens = queens | bbs[@intFromEnum(PieceType.Bishop)] | bbs[@intFromEnum(PieceType.Bishop) + 6];

        attdef |= tables.lookupBishopAttacks(to_sq, occ) & bishop_queens;
        attdef |= tables.lookupRookAttacks(to_sq, occ) & rook_queens;
    }

    while (d > 0) : (d -= 1) {
        gain[d - 1] = -@max(-gain[d - 1], gain[d]);
    }

    return gain[0];
}
