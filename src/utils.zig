const builtin = @import("builtin");
const std = @import("std");
const tables = @import("tables.zig");
const Piece = @import("piece.zig").Piece;

pub const Color = enum(u1) {
    White = 0,
    Black = 1,
    pub inline fn opp(self: Color) Color {
        return @enumFromInt(@intFromEnum(self) ^ 1);
    }
    pub inline fn piecetype_offset(self: Color) usize {
        if (self == .White) return 0;
        return 6;
    }
};

pub const Bitboard = u64;

pub fn pieceToSymbol(raw: u8) []const u8 {
    if (raw == 0) return " ";
    const piece: Piece = @bitCast(raw);
    const is_white = piece.white;
    if (piece.king) return if (is_white) "♚" else "♔";
    if (piece.queen) return if (is_white) "♛" else "♕";
    if (piece.rook) return if (is_white) "♜" else "♖";
    if (piece.bishop) return if (is_white) "♝" else "♗";
    if (piece.knight) return if (is_white) "♞" else "♘";
    if (piece.pawn) return if (is_white) "♟" else "♙";
    return "?";
}

pub fn printBoard(mat: [8][8]u8) void {
    std.debug.print("\n    a   b   c   d   e   f   g   h\n", .{});
    std.debug.print("  +---+---+---+---+---+---+---+---+\n", .{});
    for (0..8) |i| {
        const row_idx = 7 - i;
        const row = mat[row_idx];
        const rank_label: u8 = '1' + @as(u8, @intCast(row_idx));
        std.debug.print("{c} |", .{rank_label});
        for (row) |item| {
            std.debug.print(" {s} |", .{pieceToSymbol(item)});
        }
        std.debug.print(" {c}\n", .{rank_label});
        std.debug.print("  +---+---+---+---+---+---+---+---+\n", .{});
    }
    std.debug.print("    a   b   c   d   e   f   g   h\n\n", .{});
}

pub fn printBitboard(bb: Bitboard) void {
    std.debug.print("Bitboard for {b}\n", .{bb});
    std.debug.print("    a   b   c   d   e   f   g   h\n", .{});
    std.debug.print("  +---+---+---+---+---+---+---+---+\n", .{});
    for (0..8) |i| {
        const row_idx = 7 - i;
        std.debug.print("{c} |", .{'1' + @as(u8, @intCast(row_idx))});
        for (0..8) |j| {
            const square_index = row_idx * 8 + j;
            const occupied = (bb & (@as(Bitboard, 1) << @intCast(square_index))) != 0;
            std.debug.print(" {c} |", .{@as(u8, if (occupied) '*' else ' ')});
        }
        std.debug.print(" {c}\n", .{'1' + @as(u8, @intCast(row_idx))});
        std.debug.print("  +---+---+---+---+---+---+---+---+\n", .{});
    }
    std.debug.print("    a   b   c   d   e   f   g   h\n\n", .{});
}

pub fn san2idx(san: []const u8) !u6 {
    if (san.len != 2) return error.InvalidSAN;
    const file = san[0];
    const rank = san[1];
    if (file < 'a' or file > 'h') return error.InvalidSAN;
    if (rank < '1' or rank > '8') return error.InvalidSAN;
    const file_index = file - 'a';
    const rank_index = rank - '1';
    return @intCast(rank_index * 8 + file_index);
}

pub fn idx2san(sq: u6) [2]u8 {
    const file: u8 = 'a' + @as(u8, fileFromSquare(sq));
    const rank: u8 = @as(u8, rankFromSquare(sq) + 1) + '0';
    return .{ file, rank };
}

pub const FILES: [8]u64 = .{
    0x0101010101010101,
    0x202020202020202,
    0x404040404040404,
    0x808080808080808,
    0x1010101010101010,
    0x2020202020202020,
    0x4040404040404040,
    0x8080808080808080,
};

pub const RANKS: [8]u64 = .{
    0xff,
    0xff00,
    0xff0000,
    0xff000000,
    0xff00000000,
    0xff0000000000,
    0xff000000000000,
    0xff00000000000000,
};

pub const MAIN_DIAG: u64 = 0x8040201008040201;
pub const MAIN_ANTIDIAG: u64 = 0x0102040810204080;

pub const CASTLING_SQUARES: [4]u64 = .{ 0b11 << 5, 0b11 << 1, 0, 0 };

pub fn relativeRank(rank: u8, color: Color) Bitboard {
    return if (color == Color.White)
        RANKS[@as(usize, rank)]
    else
        RANKS[7 - @as(usize, rank)];
}

pub fn rankFromSquare(square: u6) u6 {
    return square >> 3;
}

pub fn fileFromSquare(square: u6) u6 {
    return square & 7;
}

pub fn maskFile(square: u6) Bitboard {
    return FILES[square & 7];
}

pub fn maskRank(square: u6) Bitboard {
    return RANKS[square >> 3];
}

pub fn maskDiag(square: u6) Bitboard {
    const bb: Bitboard = MAIN_DIAG;
    const rank = rankFromSquare(square);
    const file = fileFromSquare(square);
    return if (rank > file) bb << (rank - file) * 8 else bb >> (file - rank) * 8;
}

pub fn maskAntiDiag(square: u6) Bitboard {
    const bb: Bitboard = MAIN_ANTIDIAG;
    const rank = rankFromSquare(square);
    const file = fileFromSquare(square);
    const delta = @as(i8, rank + file) - 7;
    return if (delta < 0) bb >> @as(u6, @intCast(-delta)) * 8 else bb << @as(u6, @intCast(delta)) * 8;
}

pub fn combineBitboards(bbs: []const Bitboard) Bitboard {
    var combined_bb: Bitboard = 0;
    for (bbs) |bb| {
        combined_bb |= bb;
    }
    return combined_bb;
}

pub fn pext(src: u64, mask: u64) u64 {
    if (builtin.cpu.has(.x86, .bmi2)) {
        return asm ("pext %[mask], %[src], %[out]"
            : [out] "=r" (-> u64),
            : [src] "r" (src),
              [mask] "r" (mask),
        );
    }
    @panic("BMI2 is not available");
}

pub fn parseNextInt(parts: anytype, comptime T: type) ?T {
    const tok = parts.next() orelse return null;
    return std.fmt.parseInt(T, tok, 10) catch null;
}
