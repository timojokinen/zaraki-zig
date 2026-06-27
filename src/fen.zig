const std = @import("std");

const Color = @import("utils.zig").Color;
const pieceToSymbol = @import("utils.zig").pieceToSymbol;
const san2idx = @import("utils.zig").san2idx;
const printBoard = @import("utils.zig").printBoard;
const Piece = @import("piece.zig").Piece;
const makePiece = @import("piece.zig").makePiece;
const zobrist = @import("zobrist.zig");

const FENParsingError = error{
    InvalidPartCount,
};

pub const CastlingRights = packed struct(u4) {
    white_kingside: bool,
    white_queenside: bool,
    black_kingside: bool,
    black_queenside: bool,
};

pub const BoardState = struct {
    side_to_move: Color,
    castling_rights: CastlingRights,
    en_passant_square: ?u6,
    halfmove_clock: u32,
    fullmove_number: u32,
};

pub fn parseFen(fen: []const u8) !struct { [12]u64, u64, BoardState } {
    var iterator = std.mem.splitAny(u8, fen, " ");
    var mat_8x8: [8][8]u8 = .{.{0} ** 8} ** 8;

    const piece_placement = iterator.next() orelse return FENParsingError.InvalidPartCount;

    var ranks = std.mem.splitAny(u8, piece_placement, "/");
    for (0..8) |fen_rank_idx| {
        const rank = ranks.next() orelse return FENParsingError.InvalidPartCount;
        const row_idx = 7 - fen_rank_idx;
        var col: usize = 0;
        for (rank) |char| {
            if (char >= '1' and char <= '8') {
                const empty_squares = char - '0';
                col += empty_squares;
                continue;
            }
            const piece: Piece = switch (char) {
                'P' => makePiece(.White, .Pawn),
                'N' => makePiece(.White, .Knight),
                'B' => makePiece(.White, .Bishop),
                'R' => makePiece(.White, .Rook),
                'Q' => makePiece(.White, .Queen),
                'K' => makePiece(.White, .King),
                'p' => makePiece(.Black, .Pawn),
                'n' => makePiece(.Black, .Knight),
                'b' => makePiece(.Black, .Bishop),
                'r' => makePiece(.Black, .Rook),
                'q' => makePiece(.Black, .Queen),
                'k' => makePiece(.Black, .King),
                else => {
                    std.debug.print("Invalid character in FEN: {c}\n", .{char});
                    return FENParsingError.InvalidPartCount;
                },
            };
            mat_8x8[row_idx][col] = @bitCast(piece);
            col += 1;
        }
    }

    const side_to_move_str = iterator.next() orelse return FENParsingError.InvalidPartCount;
    const side_to_move: Color = switch (side_to_move_str[0]) {
        'w' => .White,
        'b' => .Black,
        else => {
            std.debug.print("Invalid side to move in FEN: {c}\n", .{side_to_move_str[0]});
            return FENParsingError.InvalidPartCount;
        },
    };

    const castling_rights_str = iterator.next() orelse return FENParsingError.InvalidPartCount;
    const castling_rights: CastlingRights = .{
        .white_kingside = std.mem.containsAtLeast(u8, castling_rights_str, 1, "K"),
        .white_queenside = std.mem.containsAtLeast(u8, castling_rights_str, 1, "Q"),
        .black_kingside = std.mem.containsAtLeast(u8, castling_rights_str, 1, "k"),
        .black_queenside = std.mem.containsAtLeast(u8, castling_rights_str, 1, "q"),
    };

    const en_passant_target = iterator.next() orelse return FENParsingError.InvalidPartCount;
    const en_passant_sqidx: ?u6 = if (en_passant_target[0] != '-')
        try san2idx(en_passant_target)
    else
        null;

    const halfmove_clock_str = iterator.next() orelse "0";
    const halfmove_clock = try std.fmt.parseInt(u32, halfmove_clock_str, 10);

    const fullmove_number_str = iterator.next() orelse "0";
    const fullmove_number = try std.fmt.parseInt(u32, fullmove_number_str, 10);

    const board_state: BoardState = .{ .castling_rights = castling_rights, .halfmove_clock = halfmove_clock, .fullmove_number = fullmove_number, .en_passant_square = en_passant_sqidx, .side_to_move = side_to_move };

    var bbs: [12]u64 = .{0} ** 12;
    var hash: u64 = 0;

    if (board_state.side_to_move == .Black) hash ^= zobrist.black_key;
    for (0..8) |rank| {
        inner: for (0..8) |file| {
            if (mat_8x8[rank][file] == 0) continue :inner;
            const square: u6 = @intCast(rank * 8 + file);
            const piece: Piece = @bitCast(mat_8x8[rank][file]);
            const bb_idx = @intFromEnum(piece.type()) + (@as(u4, (if (piece.white) 0 else 6)));
            bbs[bb_idx] |= @as(u64, 1) << @intCast(square);
            hash ^= zobrist.piece_keys[bb_idx][square];
        }
    }

    hash ^= zobrist.castling_rights_keys[@as(u4, @bitCast(board_state.castling_rights))];

    if (board_state.en_passant_square) |ep_sq| {
        hash ^= zobrist.ep_keys[ep_sq & 7];
    }

    return .{ bbs, hash, board_state };
}
