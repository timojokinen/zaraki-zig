const std = @import("std");

const tables = @import("tables.zig");
const attacks = @import("attacks.zig");
const BoardState = @import("fen.zig").BoardState;

const Move = @import("move.zig").Move;
const MoveList = @import("move.zig").MoveList;
const MoveFlags = @import("move.zig").MoveFlags;
const parseFen = @import("fen.zig").parseFen;
const Piece = @import("piece.zig").Piece;
const PieceType = @import("piece.zig").PieceType;
const utils = @import("utils.zig");
const printBitboard = utils.printBitboard;
const Color = utils.Color;
const Bitboard = utils.Bitboard;
const CastlingRights = @import("fen.zig").CastlingRights;
const zobrist = @import("zobrist.zig");
const enumerateBitboard = utils.enumerateBitboard;

pub const UndoInfo = struct { captured_piece: ?PieceType, castling_rights: CastlingRights, en_passant_square: ?u6, half_move_clock: u32, hash: u64 };

pub const Position = struct {
    board_state: BoardState,
    bbs: [12]Bitboard = .{0} ** 12,
    undo_stack: [256]UndoInfo = undefined,
    undo_index: u8 = 0,
    hash: u64 = undefined,

    pub fn createFromFen(fen: []const u8) !Position {
        const bbs, const hash, const board_state = try parseFen(fen);
        const pos = Position{ .board_state = board_state, .bbs = bbs, .hash = hash };
        return pos;
    }

    pub fn applyFen(self: *Position, fen: []const u8) !void {
        const bbs, const hash, const board_state = try parseFen(fen);
        self.undo_stack = undefined;
        self.undo_index = 0;
        self.hash = hash;
        self.bbs = bbs;
        self.board_state = board_state;
    }

    pub fn makeMove(self: *Position, move: Move) !void {
        const piece_type: ?PieceType = self.pieceAt(move.from_sq);
        if (piece_type == null) return error.InvalidMove;

        const captured_piece_type = self.pieceAt(move.to_sq);
        self.undo_stack[self.undo_index] = .{
            .captured_piece = captured_piece_type,
            .castling_rights = self.board_state.castling_rights,
            .en_passant_square = self.board_state.en_passant_square,
            .half_move_clock = self.board_state.halfmove_clock,
            .hash = self.hash,
        };
        self.undo_index += 1;

        const ally_color: Color = self.board_state.side_to_move;
        const color_offset: u4 = if (ally_color == Color.Black) 6 else 0;
        const opp_color_offset: u4 = if (ally_color == Color.Black) 0 else 6;

        const from_bb: Bitboard = @as(u64, 1) << move.from_sq;
        const to_bb: Bitboard = @as(u64, 1) << move.to_sq;
        const from_to_bb: Bitboard = from_bb ^ to_bb;

        const move_flags: u4 = @intFromEnum(move.flags);
        const is_capture = move_flags & 0b0100 != 0;
        const is_promotion = move_flags & 0b1000 != 0;
        const is_ep = move.flags == .EP_CAPTURE;
        const is_castle = move.flags == .KING_CASTLE or move.flags == .QUEEN_CASTLE;

        var piece_sqs = if (!is_promotion) from_to_bb else from_bb;
        self.bbs[@intFromEnum(piece_type.?) + color_offset] ^= piece_sqs;
        while (piece_sqs != 0) : (piece_sqs &= piece_sqs - 1)
            self.hash ^= zobrist.piece_keys[@intFromEnum(piece_type.?) + color_offset][@ctz(piece_sqs)];

        if (is_capture and !is_ep) {
            if (captured_piece_type == null) return error.InvalidMove;
            self.bbs[@intFromEnum(captured_piece_type.?) + opp_color_offset] ^= to_bb;
            self.hash ^= zobrist.piece_keys[@intFromEnum(captured_piece_type.?) + opp_color_offset][move.to_sq];
        }

        if (is_ep) {
            const captured_pawn_sq: u6 = if (ally_color == .White) self.board_state.en_passant_square.? - 8 else self.board_state.en_passant_square.? + 8;
            self.bbs[@intFromEnum(PieceType.Pawn) + opp_color_offset] ^= @as(u64, 1) << captured_pawn_sq;
            self.hash ^= zobrist.piece_keys[@intFromEnum(PieceType.Pawn) + opp_color_offset][captured_pawn_sq];
        }

        if (is_promotion) {
            const prom_piece: PieceType = switch (move.flags) {
                .KNIGHT_PROMOTION, .KNIGHT_PROMOTION_CAPTURE => PieceType.Knight,
                .BISHOP_PROMOTION, .BISHOP_PROMOTION_CAPTURE => PieceType.Bishop,
                .ROOK_PROMOTION, .ROOK_PROMOTION_CAPTURE => PieceType.Rook,
                .QUEEN_PROMOTION, .QUEEN_PROMOTION_CAPTURE => PieceType.Queen,
                else => unreachable,
            };
            self.bbs[@intFromEnum(prom_piece) + color_offset] |= to_bb;
            self.hash ^= zobrist.piece_keys[@intFromEnum(prom_piece) + color_offset][move.to_sq];
        }

        if (is_castle) {
            const relative_sq: u6 = if (ally_color == .Black) 56 else 0;
            var rook_sqs = switch (move.flags) {
                .KING_CASTLE => @as(u64, 1) << (7 + relative_sq) | @as(u64, 1) << (5 + relative_sq),
                .QUEEN_CASTLE => @as(u64, 1) << (3 + relative_sq) | @as(u64, 1) << (0 + relative_sq),
                else => unreachable,
            };
            self.bbs[@intFromEnum(PieceType.Rook) + color_offset] ^= rook_sqs;

            while (rook_sqs != 0) : (rook_sqs &= rook_sqs - 1)
                self.hash ^= zobrist.piece_keys[@intFromEnum(PieceType.Rook) + color_offset][@ctz(rook_sqs)];
        }

        self.hash ^= zobrist.castling_rights_keys[@as(u4, @bitCast(self.board_state.castling_rights))];
        if (move.from_sq == 4 or move.from_sq == 7 or move.to_sq == 7) self.board_state.castling_rights.white_kingside = false;
        if (move.from_sq == 4 or move.from_sq == 0 or move.to_sq == 0) self.board_state.castling_rights.white_queenside = false;
        if (move.from_sq == 60 or move.from_sq == 63 or move.to_sq == 63) self.board_state.castling_rights.black_kingside = false;
        if (move.from_sq == 60 or move.from_sq == 56 or move.to_sq == 56) self.board_state.castling_rights.black_queenside = false;
        self.hash ^= zobrist.castling_rights_keys[@as(u4, @bitCast(self.board_state.castling_rights))];

        if (self.board_state.en_passant_square) |old_ep| {
            self.hash ^= zobrist.ep_keys[old_ep & 7];
        }
        if (move.flags == .DOUBLE_PAWN_PUSH) {
            const new_ep = if (ally_color == .White) move.to_sq - 8 else move.to_sq + 8;
            self.board_state.en_passant_square = new_ep;
            self.hash ^= zobrist.ep_keys[new_ep & 7];
        } else {
            self.board_state.en_passant_square = null;
        }

        if (is_capture or piece_type.? == .Pawn) {
            self.board_state.halfmove_clock = 0;
        } else {
            self.board_state.halfmove_clock += 1;
        }

        if (ally_color == .Black) self.board_state.fullmove_number += 1;

        const opp_color = ally_color.opp();
        self.board_state.side_to_move = opp_color;
        self.hash ^= zobrist.black_key;
    }

    pub fn unmakeMove(self: *Position, move: Move) !void {
        self.undo_index -= 1;
        const undo = self.undo_stack[self.undo_index];
        self.board_state.castling_rights = undo.castling_rights;
        self.board_state.en_passant_square = undo.en_passant_square;
        self.board_state.halfmove_clock = undo.half_move_clock;
        self.hash = undo.hash;

        const piece_type = self.pieceAt(move.to_sq);
        if (piece_type == null) return error.InvalidMove;

        const opp_color = self.board_state.side_to_move;
        const ally_color = opp_color.opp();
        const color_offset: u4 = if (ally_color == .Black) 6 else 0;
        const opp_color_offset: u4 = if (ally_color == .Black) 0 else 6;
        self.board_state.side_to_move = ally_color;

        const to_bb: Bitboard = @as(u64, 1) << move.to_sq;
        const from_bb: Bitboard = @as(u64, 1) << move.from_sq;
        const from_to_bb: Bitboard = to_bb ^ from_bb;

        const move_flags: u4 = @intFromEnum(move.flags);
        const is_capture = move_flags & 0b0100 != 0;
        const is_promotion = move_flags & 0b1000 != 0;
        const is_ep = move.flags == .EP_CAPTURE;
        const is_castle = move.flags == .KING_CASTLE or move.flags == .QUEEN_CASTLE;

        if (!is_promotion) {
            self.bbs[@intFromEnum(piece_type.?) + color_offset] ^= from_to_bb;
        } else {
            self.bbs[@intFromEnum(piece_type.?) + color_offset] ^= to_bb;
            self.bbs[@intFromEnum(PieceType.Pawn) + color_offset] |= from_bb;
        }

        if (is_capture and !is_ep) {
            self.bbs[@intFromEnum(undo.captured_piece.?) + opp_color_offset] ^= to_bb;
        }

        if (is_ep) {
            const captured_pawn_sq: u6 = if (ally_color == .White) undo.en_passant_square.? - 8 else undo.en_passant_square.? + 8;
            self.bbs[@intFromEnum(PieceType.Pawn) + opp_color_offset] ^= @as(u64, 1) << captured_pawn_sq;
        }

        if (is_castle) {
            const relative_sq: u6 = if (ally_color == .Black) 56 else 0;
            self.bbs[@intFromEnum(PieceType.Rook) + color_offset] ^= switch (move.flags) {
                .KING_CASTLE => @as(u64, 1) << (7 + relative_sq) | @as(u64, 1) << (5 + relative_sq),
                .QUEEN_CASTLE => @as(u64, 1) << (3 + relative_sq) | @as(u64, 1) << (0 + relative_sq),
                else => unreachable,
            };
        }

        if (ally_color == .Black) self.board_state.fullmove_number -= 1;
    }

    pub fn makeNullMove(self: *Position) void {
        self.undo_stack[self.undo_index] = .{
            .captured_piece = null,
            .castling_rights = self.board_state.castling_rights,
            .en_passant_square = self.board_state.en_passant_square,
            .half_move_clock = self.board_state.halfmove_clock,
            .hash = self.hash,
        };
        self.undo_index += 1;

        const ally_color: Color = self.board_state.side_to_move;

        self.board_state.halfmove_clock += 1;
        if (ally_color == .Black) self.board_state.fullmove_number += 1;

        if (self.board_state.en_passant_square) |old_ep| {
            self.hash ^= zobrist.ep_keys[old_ep & 7];
            self.board_state.en_passant_square = null;
        }

        const opp_color = ally_color.opp();
        self.board_state.side_to_move = opp_color;
        self.hash ^= zobrist.black_key;
    }

    pub fn unmakeNullMove(self: *Position) void {
        self.undo_index -= 1;
        const undo = self.undo_stack[self.undo_index];
        self.board_state.castling_rights = undo.castling_rights;
        self.board_state.en_passant_square = undo.en_passant_square;
        self.board_state.halfmove_clock = undo.half_move_clock;
        self.hash = undo.hash;

        const opp_color = self.board_state.side_to_move;
        const ally_color = opp_color.opp();
        self.board_state.side_to_move = ally_color;

        if (ally_color == .Black) self.board_state.fullmove_number -= 1;
    }

    pub fn pieceAt(self: Position, sq: u6) ?PieceType {
        const bit = @as(u64, 1) << sq;
        inline for ([_]PieceType{ .Pawn, .Knight, .Bishop, .Rook, .Queen, .King }) |pt| {
            const idx = @intFromEnum(pt);
            const combined = self.bbs[idx] | self.bbs[idx + 6];
            if ((combined & bit) != 0) return pt;
        }
        return null;
    }

    pub fn inCheck(self: Position) bool {
        const ally_color: Color = self.board_state.side_to_move;
        const color_offset: usize = if (ally_color == Color.Black) 6 else 0;
        const all_pieces_bb: Bitboard = utils.combineBitboards(&self.bbs);
        const king_bb: Bitboard = self.bbs[@intFromEnum(PieceType.King) + color_offset];
        const king_sq: u6 = @intCast(@ctz(king_bb));
        const king_attackers: Bitboard = attacks.squareAttackers(king_sq, ally_color.opp(), self.bbs, all_pieces_bb);
        return king_attackers > 0;
    }

    pub fn generateMoves(self: Position, move_list: *MoveList) !void {
        move_list.count = 0;
        const ally_color: Color = self.board_state.side_to_move;
        const color_offset: usize = if (ally_color == Color.Black) 6 else 0;
        const opp_color_offset: usize = if (ally_color == Color.Black) 0 else 6;
        const all_pieces_bb: Bitboard = utils.combineBitboards(&self.bbs);
        const ally_pieces_bb: Bitboard = utils.combineBitboards(self.bbs[color_offset..][0..6]);
        const opp_pieces_bb: Bitboard = utils.combineBitboards(self.bbs[(color_offset + 6) % 12 ..][0..6]);
        const king_bb: Bitboard = self.bbs[@intFromEnum(PieceType.King) + color_offset];
        const king_sq: u6 = @intCast(@ctz(king_bb));
        const opp_attacks: Bitboard = attacks.pieceAttacks(ally_color.opp(), self.bbs, all_pieces_bb ^ king_bb);
        const king_attackers: Bitboard = attacks.squareAttackers(king_sq, ally_color.opp(), self.bbs, all_pieces_bb);
        const checkers_count = @popCount(king_attackers);

        {
            const att: Bitboard = tables.lookupKingAttacks(king_sq) & ~ally_pieces_bb & ~opp_attacks;

            var quiet: Bitboard = att & ~opp_pieces_bb;
            var capture: Bitboard = att & opp_pieces_bb;

            while (quiet != 0) : (quiet &= quiet - 1) {
                const to_sq: u6 = @intCast(@ctz(quiet));
                move_list.add(.{ .flags = MoveFlags.QUIET, .from_sq = king_sq, .to_sq = to_sq });
            }

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = king_sq, .to_sq = to_sq });
            }

            const wk_attacked = 0b111 << 4;
            const wk_blocked = 0b11 << 5;
            const wq_attacked = 0b111 << 2;
            const wq_blocked = 0b111 << 1;
            const bk_attacked = 0b111 << 60;
            const bk_blocked = 0b11 << 61;
            const bq_attacked = 0b111 << 58;
            const bq_blocked = 0b111 << 57;

            if (ally_color == Color.White and
                self.board_state.castling_rights.white_kingside and
                wk_attacked & opp_attacks == 0 and
                wk_blocked & all_pieces_bb == 0)
            {
                move_list.add(.{ .flags = MoveFlags.KING_CASTLE, .from_sq = king_sq, .to_sq = 6 });
            }

            if (ally_color == Color.White and
                self.board_state.castling_rights.white_queenside and
                wq_attacked & opp_attacks == 0 and
                wq_blocked & all_pieces_bb == 0)
            {
                move_list.add(.{ .flags = MoveFlags.QUEEN_CASTLE, .from_sq = king_sq, .to_sq = 2 });
            }

            if (ally_color == Color.Black and
                self.board_state.castling_rights.black_kingside and
                bk_attacked & opp_attacks == 0 and
                bk_blocked & all_pieces_bb == 0)
            {
                move_list.add(.{ .flags = MoveFlags.KING_CASTLE, .from_sq = king_sq, .to_sq = 62 });
            }

            if (ally_color == Color.Black and
                self.board_state.castling_rights.black_queenside and
                bq_attacked & opp_attacks == 0 and
                bq_blocked & all_pieces_bb == 0)
            {
                move_list.add(.{ .flags = MoveFlags.QUEEN_CASTLE, .from_sq = king_sq, .to_sq = 58 });
            }
        }

        if (checkers_count >= 2) return;

        const rook_queen_pinners = attacks.xRayRookAttacks(@intCast(@ctz(king_bb)), all_pieces_bb, ally_pieces_bb) & (self.bbs[@intFromEnum(PieceType.Queen) + opp_color_offset] | self.bbs[@intFromEnum(PieceType.Rook) + opp_color_offset]);
        const bishop_queen_pinners = attacks.xRayBishopAttacks(@intCast(@ctz(king_bb)), all_pieces_bb, ally_pieces_bb) & (self.bbs[@intFromEnum(PieceType.Queen) + opp_color_offset] | self.bbs[@intFromEnum(PieceType.Bishop) + opp_color_offset]);

        var pinned_pieces: Bitboard = 0;
        var pinner = rook_queen_pinners;
        while (pinner != 0) : (pinner &= pinner - 1) {
            const pinner_sq: u6 = @intCast(@ctz(pinner));
            pinned_pieces |= tables.lookupSquaresBetween(pinner_sq, king_sq) & ally_pieces_bb;
        }

        pinner = bishop_queen_pinners;
        while (pinner != 0) : (pinner &= pinner - 1) {
            const pinner_sq: u6 = @intCast(@ctz(pinner));
            pinned_pieces |= tables.lookupSquaresBetween(pinner_sq, king_sq) & ally_pieces_bb;
        }

        const checker_sq: ?u6 = if (checkers_count == 1) @intCast(@ctz(king_attackers)) else null;
        const check_mask: Bitboard = if (checker_sq) |sq| tables.lookupSquaresBetween(sq, king_sq) | (@as(u64, 1) << sq) else ~@as(Bitboard, 0);

        var pawns_bb: Bitboard = self.bbs[@intFromEnum(PieceType.Pawn) + color_offset];
        const pawn_direction: i8 = if (ally_color == Color.White) 1 else -1;
        const promotion_rank: Bitboard = utils.relativeRank(7, ally_color);

        while (pawns_bb != 0) : (pawns_bb &= pawns_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(pawns_bb));
            const from_bb: Bitboard = @as(u64, 1) << from_sq;
            const raw_att: Bitboard = tables.lookupPawnAttacks(from_sq, ally_color);
            const is_pinned: bool = pinned_pieces & @as(u64, 1) << from_sq != 0;
            var pin_mask: Bitboard = ~@as(Bitboard, 0);
            if (is_pinned) {
                var pot_pinners: Bitboard = bishop_queen_pinners | rook_queen_pinners;
                while (pot_pinners != 0) : (pot_pinners &= pot_pinners - 1) {
                    const pot_pinner: u6 = @intCast(@ctz(pot_pinners));
                    const pinner_ray: Bitboard = tables.lookupSquaresBetween(king_sq, pot_pinner) | @as(u64, 1) << pot_pinner;
                    if (pinner_ray & from_bb != 0) {
                        pin_mask &= pinner_ray;
                        continue;
                    }
                }
            }

            var to_sq: u6 = @intCast(@as(i8, from_sq) + 8 * pawn_direction);
            const to_bb: Bitboard = @as(u64, 1) << to_sq;

            if (to_bb & ~all_pieces_bb & pin_mask & check_mask != 0) {
                if (to_bb & promotion_rank != 0) {
                    move_list.add(.{ .flags = MoveFlags.KNIGHT_PROMOTION, .to_sq = to_sq, .from_sq = from_sq });
                    move_list.add(.{ .flags = MoveFlags.BISHOP_PROMOTION, .to_sq = to_sq, .from_sq = from_sq });
                    move_list.add(.{ .flags = MoveFlags.ROOK_PROMOTION, .to_sq = to_sq, .from_sq = from_sq });
                    move_list.add(.{ .flags = MoveFlags.QUEEN_PROMOTION, .to_sq = to_sq, .from_sq = from_sq });
                } else {
                    move_list.add(.{ .flags = MoveFlags.QUIET, .to_sq = to_sq, .from_sq = from_sq });
                }
            }

            if (to_bb & ~all_pieces_bb & ~promotion_rank != 0) {
                to_sq = @intCast(@as(i8, to_sq) + 8 * pawn_direction);
                if (@as(u64, 1) << to_sq & ~all_pieces_bb & pin_mask & check_mask != 0 and from_bb & utils.relativeRank(1, ally_color) != 0) {
                    move_list.add(.{ .flags = MoveFlags.DOUBLE_PAWN_PUSH, .from_sq = from_sq, .to_sq = to_sq });
                }
            }

            const att: Bitboard = raw_att & opp_pieces_bb & pin_mask & check_mask;

            var captures: Bitboard = att & ~promotion_rank;
            var prom_captures: Bitboard = att & promotion_rank;

            while (captures != 0) : (captures &= captures - 1) {
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = @intCast(@ctz(captures)) });
            }
            while (prom_captures != 0) : (prom_captures &= prom_captures - 1) {
                to_sq = @intCast(@ctz(prom_captures));
                move_list.add(.{ .flags = MoveFlags.KNIGHT_PROMOTION_CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
                move_list.add(.{ .flags = MoveFlags.BISHOP_PROMOTION_CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
                move_list.add(.{ .flags = MoveFlags.ROOK_PROMOTION_CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
                move_list.add(.{ .flags = MoveFlags.QUEEN_PROMOTION_CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }

            if (self.board_state.en_passant_square) |ep_sq| {
                const ep_att = raw_att & (@as(u64, 1) << ep_sq) & pin_mask;
                const captured_sq: u6 = @intCast(@as(i8, ep_sq) - 8 * pawn_direction);
                const ep_resolved_check = if (checker_sq) |sq| sq == captured_sq else true;
                if (ep_att != 0 and ep_resolved_check) {
                    const occ_after = (all_pieces_bb ^ from_bb ^ (@as(u64, 1) << captured_sq)) | (@as(u64, 1) << ep_sq);
                    const opp_rook_queen = (self.bbs[@intFromEnum(PieceType.Rook) + opp_color_offset] | self.bbs[@intFromEnum(PieceType.Queen) + opp_color_offset]);
                    const exposes_check = tables.lookupRookAttacks(king_sq, occ_after) & opp_rook_queen != 0;
                    if (exposes_check == false) {
                        move_list.add(.{ .flags = MoveFlags.EP_CAPTURE, .from_sq = from_sq, .to_sq = ep_sq });
                    }
                }
            }
        }

        var knights_bb = self.bbs[@intFromEnum(PieceType.Knight) + color_offset] & ~pinned_pieces;
        while (knights_bb != 0) : (knights_bb &= knights_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(knights_bb));
            const att: Bitboard = tables.lookupKnightAttacks(from_sq) & ~ally_pieces_bb & check_mask;

            var quiet: Bitboard = att & ~opp_pieces_bb;
            var capture: Bitboard = att & opp_pieces_bb;

            while (quiet != 0) : (quiet &= quiet - 1) {
                const to_sq: u6 = @intCast(@ctz(quiet));
                move_list.add(.{ .flags = MoveFlags.QUIET, .from_sq = from_sq, .to_sq = to_sq });
            }

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }
        }

        var bishops_bb = self.bbs[@intFromEnum(PieceType.Bishop) + color_offset];
        while (bishops_bb != 0) : (bishops_bb &= bishops_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(bishops_bb));
            var att: Bitboard = tables.lookupBishopAttacks(from_sq, all_pieces_bb) & ~ally_pieces_bb & check_mask;
            if (pinned_pieces & @as(u64, 1) << from_sq != 0) {
                const bishop_queen_pinning_bishop = bishop_queen_pinners & att;
                if (bishop_queen_pinning_bishop == 0) continue;
                att &= tables.lookupSquaresBetween(@intCast(@ctz(bishop_queen_pinning_bishop)), king_sq) | bishop_queen_pinning_bishop;
            }

            var quiet: Bitboard = att & ~opp_pieces_bb;
            var capture: Bitboard = att & opp_pieces_bb;

            while (quiet != 0) : (quiet &= quiet - 1) {
                const to_sq: u6 = @intCast(@ctz(quiet));
                move_list.add(.{ .flags = MoveFlags.QUIET, .from_sq = from_sq, .to_sq = to_sq });
            }

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }
        }

        var rooks_bb = self.bbs[@intFromEnum(PieceType.Rook) + color_offset];
        while (rooks_bb != 0) : (rooks_bb &= rooks_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(rooks_bb));
            const from_bb: Bitboard = @as(u64, 1) << from_sq;
            const raw_att: Bitboard = tables.lookupRookAttacks(from_sq, all_pieces_bb);
            var pin_mask: Bitboard = ~@as(Bitboard, 0);

            if (pinned_pieces & from_bb != 0) {
                var pot_pinners: Bitboard = rook_queen_pinners | bishop_queen_pinners;
                while (pot_pinners != 0) : (pot_pinners &= pot_pinners - 1) {
                    const pot_pinner: u6 = @intCast(@ctz(pot_pinners));
                    const pinner_ray: Bitboard = tables.lookupSquaresBetween(king_sq, pot_pinner) | @as(u64, 1) << pot_pinner;
                    if (pinner_ray & from_bb != 0) {
                        pin_mask &= pinner_ray;
                        continue;
                    }
                }
            }

            const att: Bitboard = raw_att & ~ally_pieces_bb & check_mask & pin_mask;
            var quiet: Bitboard = att & ~opp_pieces_bb;
            var capture: Bitboard = att & opp_pieces_bb;

            while (quiet != 0) : (quiet &= quiet - 1) {
                const to_sq: u6 = @intCast(@ctz(quiet));
                move_list.add(.{ .flags = MoveFlags.QUIET, .from_sq = from_sq, .to_sq = to_sq });
            }

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }
        }

        var queens_bb = self.bbs[@intFromEnum(PieceType.Queen) + color_offset];
        while (queens_bb != 0) : (queens_bb &= queens_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(queens_bb));
            const from_bb: Bitboard = @as(u64, 1) << from_sq;
            const raw_att: Bitboard = tables.lookupQueenAttacks(from_sq, all_pieces_bb);
            var pin_mask: Bitboard = ~@as(Bitboard, 0);

            if (pinned_pieces & from_bb != 0) {
                var pot_pinners: Bitboard = bishop_queen_pinners | rook_queen_pinners;
                while (pot_pinners != 0) : (pot_pinners &= pot_pinners - 1) {
                    const pot_pinner: u6 = @intCast(@ctz(pot_pinners));
                    const pinner_ray: Bitboard = tables.lookupSquaresBetween(king_sq, pot_pinner) | @as(u64, 1) << pot_pinner;
                    if (pinner_ray & from_bb != 0) {
                        pin_mask &= pinner_ray;
                        continue;
                    }
                }
            }

            const att: Bitboard = raw_att & ~ally_pieces_bb & check_mask & pin_mask;

            var quiet: Bitboard = att & ~opp_pieces_bb;
            var capture: Bitboard = att & opp_pieces_bb;

            while (quiet != 0) : (quiet &= quiet - 1) {
                const to_sq: u6 = @intCast(@ctz(quiet));
                move_list.add(.{ .flags = MoveFlags.QUIET, .from_sq = from_sq, .to_sq = to_sq });
            }

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }
        }

        return;
    }

    pub fn generateCaptureMoves(self: Position, move_list: *MoveList) !void {
        move_list.count = 0;
        const ally_color: Color = self.board_state.side_to_move;
        const color_offset: usize = if (ally_color == Color.Black) 6 else 0;
        const opp_color_offset: usize = if (ally_color == Color.Black) 0 else 6;
        const all_pieces_bb: Bitboard = utils.combineBitboards(&self.bbs);
        const ally_pieces_bb: Bitboard = utils.combineBitboards(self.bbs[color_offset..][0..6]);
        const opp_pieces_bb: Bitboard = utils.combineBitboards(self.bbs[(color_offset + 6) % 12 ..][0..6]);
        const king_bb: Bitboard = self.bbs[@intFromEnum(PieceType.King) + color_offset];
        const king_sq: u6 = @intCast(@ctz(king_bb));
        const opp_attacks: Bitboard = attacks.pieceAttacks(ally_color.opp(), self.bbs, all_pieces_bb ^ king_bb);
        const king_attackers: Bitboard = attacks.squareAttackers(king_sq, ally_color.opp(), self.bbs, all_pieces_bb);
        const checkers_count = @popCount(king_attackers);

        {
            const att: Bitboard = tables.lookupKingAttacks(king_sq) & ~ally_pieces_bb & ~opp_attacks;

            var capture: Bitboard = att & opp_pieces_bb;

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = king_sq, .to_sq = to_sq });
            }
        }

        if (checkers_count >= 2) return;

        const rook_queen_pinners = attacks.xRayRookAttacks(@intCast(@ctz(king_bb)), all_pieces_bb, ally_pieces_bb) & (self.bbs[@intFromEnum(PieceType.Queen) + opp_color_offset] | self.bbs[@intFromEnum(PieceType.Rook) + opp_color_offset]);
        const bishop_queen_pinners = attacks.xRayBishopAttacks(@intCast(@ctz(king_bb)), all_pieces_bb, ally_pieces_bb) & (self.bbs[@intFromEnum(PieceType.Queen) + opp_color_offset] | self.bbs[@intFromEnum(PieceType.Bishop) + opp_color_offset]);

        var pinned_pieces: Bitboard = 0;
        var pinner = rook_queen_pinners;
        while (pinner != 0) : (pinner &= pinner - 1) {
            const pinner_sq: u6 = @intCast(@ctz(pinner));
            pinned_pieces |= tables.lookupSquaresBetween(pinner_sq, king_sq) & ally_pieces_bb;
        }

        pinner = bishop_queen_pinners;
        while (pinner != 0) : (pinner &= pinner - 1) {
            const pinner_sq: u6 = @intCast(@ctz(pinner));
            pinned_pieces |= tables.lookupSquaresBetween(pinner_sq, king_sq) & ally_pieces_bb;
        }

        const checker_sq: ?u6 = if (checkers_count == 1) @intCast(@ctz(king_attackers)) else null;
        const check_mask: Bitboard = if (checker_sq) |sq| tables.lookupSquaresBetween(sq, king_sq) | (@as(u64, 1) << sq) else ~@as(Bitboard, 0);

        var pawns_bb: Bitboard = self.bbs[@intFromEnum(PieceType.Pawn) + color_offset];
        const pawn_direction: i8 = if (ally_color == Color.White) 1 else -1;
        const promotion_rank: Bitboard = utils.relativeRank(7, ally_color);

        while (pawns_bb != 0) : (pawns_bb &= pawns_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(pawns_bb));
            const from_bb: Bitboard = @as(u64, 1) << from_sq;
            const raw_att: Bitboard = tables.lookupPawnAttacks(from_sq, ally_color);
            const is_pinned: bool = pinned_pieces & @as(u64, 1) << from_sq != 0;
            var pin_mask: Bitboard = ~@as(Bitboard, 0);
            if (is_pinned) {
                var pot_pinners: Bitboard = bishop_queen_pinners | rook_queen_pinners;
                while (pot_pinners != 0) : (pot_pinners &= pot_pinners - 1) {
                    const pot_pinner: u6 = @intCast(@ctz(pot_pinners));
                    const pinner_ray: Bitboard = tables.lookupSquaresBetween(king_sq, pot_pinner) | @as(u64, 1) << pot_pinner;
                    if (pinner_ray & from_bb != 0) {
                        pin_mask &= pinner_ray;
                        continue;
                    }
                }
            }

            var to_sq: u6 = @intCast(@as(i8, from_sq) + 8 * pawn_direction);
            const to_bb: Bitboard = @as(u64, 1) << to_sq;

            if (to_bb & ~all_pieces_bb & pin_mask & check_mask != 0) {
                if (to_bb & promotion_rank != 0) {
                    move_list.add(.{ .flags = MoveFlags.KNIGHT_PROMOTION, .to_sq = to_sq, .from_sq = from_sq });
                    move_list.add(.{ .flags = MoveFlags.BISHOP_PROMOTION, .to_sq = to_sq, .from_sq = from_sq });
                    move_list.add(.{ .flags = MoveFlags.ROOK_PROMOTION, .to_sq = to_sq, .from_sq = from_sq });
                    move_list.add(.{ .flags = MoveFlags.QUEEN_PROMOTION, .to_sq = to_sq, .from_sq = from_sq });
                }
            }

            const att: Bitboard = raw_att & opp_pieces_bb & pin_mask & check_mask;

            var captures: Bitboard = att & ~promotion_rank;
            var prom_captures: Bitboard = att & promotion_rank;

            while (captures != 0) : (captures &= captures - 1) {
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = @intCast(@ctz(captures)) });
            }
            while (prom_captures != 0) : (prom_captures &= prom_captures - 1) {
                to_sq = @intCast(@ctz(prom_captures));
                move_list.add(.{ .flags = MoveFlags.KNIGHT_PROMOTION_CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
                move_list.add(.{ .flags = MoveFlags.BISHOP_PROMOTION_CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
                move_list.add(.{ .flags = MoveFlags.ROOK_PROMOTION_CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
                move_list.add(.{ .flags = MoveFlags.QUEEN_PROMOTION_CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }

            if (self.board_state.en_passant_square) |ep_sq| {
                const ep_att = raw_att & (@as(u64, 1) << ep_sq) & pin_mask;
                const captured_sq: u6 = @intCast(@as(i8, ep_sq) - 8 * pawn_direction);
                const ep_resolved_check = if (checker_sq) |sq| sq == captured_sq else true;
                if (ep_att != 0 and ep_resolved_check) {
                    const occ_after = (all_pieces_bb ^ from_bb ^ (@as(u64, 1) << captured_sq)) | (@as(u64, 1) << ep_sq);
                    const opp_rook_queen = (self.bbs[@intFromEnum(PieceType.Rook) + opp_color_offset] | self.bbs[@intFromEnum(PieceType.Queen) + opp_color_offset]);
                    const exposes_check = tables.lookupRookAttacks(king_sq, occ_after) & opp_rook_queen != 0;
                    if (exposes_check == false) {
                        move_list.add(.{ .flags = MoveFlags.EP_CAPTURE, .from_sq = from_sq, .to_sq = ep_sq });
                    }
                }
            }
        }

        var knights_bb = self.bbs[@intFromEnum(PieceType.Knight) + color_offset] & ~pinned_pieces;
        while (knights_bb != 0) : (knights_bb &= knights_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(knights_bb));
            const att: Bitboard = tables.lookupKnightAttacks(from_sq) & ~ally_pieces_bb & check_mask;

            var capture: Bitboard = att & opp_pieces_bb;

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }
        }

        var bishops_bb = self.bbs[@intFromEnum(PieceType.Bishop) + color_offset];
        while (bishops_bb != 0) : (bishops_bb &= bishops_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(bishops_bb));
            var att: Bitboard = tables.lookupBishopAttacks(from_sq, all_pieces_bb) & ~ally_pieces_bb & check_mask;
            if (pinned_pieces & @as(u64, 1) << from_sq != 0) {
                const bishop_queen_pinning_bishop = bishop_queen_pinners & att;
                if (bishop_queen_pinning_bishop == 0) continue;
                att &= tables.lookupSquaresBetween(@intCast(@ctz(bishop_queen_pinning_bishop)), king_sq) | bishop_queen_pinning_bishop;
            }

            var capture: Bitboard = att & opp_pieces_bb;

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }
        }

        var rooks_bb = self.bbs[@intFromEnum(PieceType.Rook) + color_offset];
        while (rooks_bb != 0) : (rooks_bb &= rooks_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(rooks_bb));
            const from_bb: Bitboard = @as(u64, 1) << from_sq;
            const raw_att: Bitboard = tables.lookupRookAttacks(from_sq, all_pieces_bb);
            var pin_mask: Bitboard = ~@as(Bitboard, 0);

            if (pinned_pieces & from_bb != 0) {
                var pot_pinners: Bitboard = rook_queen_pinners | bishop_queen_pinners;
                while (pot_pinners != 0) : (pot_pinners &= pot_pinners - 1) {
                    const pot_pinner: u6 = @intCast(@ctz(pot_pinners));
                    const pinner_ray: Bitboard = tables.lookupSquaresBetween(king_sq, pot_pinner) | @as(u64, 1) << pot_pinner;
                    if (pinner_ray & from_bb != 0) {
                        pin_mask &= pinner_ray;
                        continue;
                    }
                }
            }

            const att: Bitboard = raw_att & ~ally_pieces_bb & check_mask & pin_mask;
            var capture: Bitboard = att & opp_pieces_bb;

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }
        }

        var queens_bb = self.bbs[@intFromEnum(PieceType.Queen) + color_offset];
        while (queens_bb != 0) : (queens_bb &= queens_bb - 1) {
            const from_sq: u6 = @intCast(@ctz(queens_bb));
            const from_bb: Bitboard = @as(u64, 1) << from_sq;
            const raw_att: Bitboard = tables.lookupQueenAttacks(from_sq, all_pieces_bb);
            var pin_mask: Bitboard = ~@as(Bitboard, 0);

            if (pinned_pieces & from_bb != 0) {
                var pot_pinners: Bitboard = bishop_queen_pinners | rook_queen_pinners;
                while (pot_pinners != 0) : (pot_pinners &= pot_pinners - 1) {
                    const pot_pinner: u6 = @intCast(@ctz(pot_pinners));
                    const pinner_ray: Bitboard = tables.lookupSquaresBetween(king_sq, pot_pinner) | @as(u64, 1) << pot_pinner;
                    if (pinner_ray & from_bb != 0) {
                        pin_mask &= pinner_ray;
                        continue;
                    }
                }
            }

            const att: Bitboard = raw_att & ~ally_pieces_bb & check_mask & pin_mask;

            var capture: Bitboard = att & opp_pieces_bb;

            while (capture != 0) : (capture &= capture - 1) {
                const to_sq: u6 = @intCast(@ctz(capture));
                move_list.add(.{ .flags = MoveFlags.CAPTURE, .from_sq = from_sq, .to_sq = to_sq });
            }
        }

        return;
    }
};
