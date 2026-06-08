const std = @import("std");
const utils = @import("utils.zig");
const search_mod = @import("search.zig");
const Position = @import("position.zig").Position;
const createPositionFromFEN = @import("position.zig").createPositionFromFEN;
const perft = @import("perft.zig").perft;
const Move = @import("move.zig").Move;
const MoveFlags = @import("move.zig").MoveFlags;

const SupportedCommands = enum {
    uci,
    ucinewgame,
    position,
    go,
    isready,
    stop,
    ponderhit,
    setoption,
    quit,
};

const PositionArguments = enum { startpos, fen };

fn moveToUci(move: Move, buf: *[5]u8) []u8 {
    const from = utils.idx2san(move.from_sq);
    const to = utils.idx2san(move.to_sq);
    buf[0] = from[0];
    buf[1] = from[1];
    buf[2] = to[0];
    buf[3] = to[1];
    const promo: u8 = switch (move.flags) {
        .QUEEN_PROMOTION, .QUEEN_PROMOTION_CAPTURE => 'q',
        .ROOK_PROMOTION, .ROOK_PROMOTION_CAPTURE => 'r',
        .BISHOP_PROMOTION, .BISHOP_PROMOTION_CAPTURE => 'b',
        .KNIGHT_PROMOTION, .KNIGHT_PROMOTION_CAPTURE => 'n',
        else => 0,
    };
    if (promo != 0) {
        buf[4] = promo;
        return buf[0..5];
    }
    return buf[0..4];
}

fn applyUciMove(position: *Position, move_str: []const u8) !void {
    if (move_str.len < 4) return error.InvalidMove;
    const from_sq = try utils.san2idx(move_str[0..2]);
    const to_sq = try utils.san2idx(move_str[2..4]);
    const promo_char: u8 = if (move_str.len >= 5) move_str[4] else 0;
    var move_list: [256]Move = undefined;
    const move_count = try position.generateMoves(&move_list);
    for (move_list[0..move_count]) |move| {
        if (move.from_sq != from_sq or move.to_sq != to_sq) continue;
        if (promo_char != 0) {
            const is_match = switch (move.flags) {
                .QUEEN_PROMOTION, .QUEEN_PROMOTION_CAPTURE => promo_char == 'q',
                .ROOK_PROMOTION, .ROOK_PROMOTION_CAPTURE => promo_char == 'r',
                .BISHOP_PROMOTION, .BISHOP_PROMOTION_CAPTURE => promo_char == 'b',
                .KNIGHT_PROMOTION, .KNIGHT_PROMOTION_CAPTURE => promo_char == 'n',
                else => false,
            };
            if (!is_match) continue;
        }
        try position.makeMove(move);
        return;
    }
    return error.MoveNotFound;
}

pub fn uciInterface(io: std.Io) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin: *std.Io.Reader = &stdin_reader.interface;

    const startpos_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    var position: Position = try createPositionFromFEN(startpos_fen);

    while (true) {
        defer stdout.flush() catch {};

        const bare_line = try stdin.takeDelimiter('\n') orelse break;
        const line = std.mem.trim(u8, bare_line, "\r\n");
        if (line.len == 0) continue;

        var cmd_parts = std.mem.splitAny(u8, line, " ");
        const raw_cmd = cmd_parts.next() orelse continue;
        const cmd = std.meta.stringToEnum(SupportedCommands, raw_cmd) orelse continue;

        switch (cmd) {
            .quit => break,
            .uci => {
                try stdout.writeAll("id name Vanta 0.1\n");
                try stdout.writeAll("id author Timo Jokinen\n");
                try stdout.writeAll("uciok\n");
            },
            .isready => try stdout.writeAll("readyok\n"),
            .ucinewgame => {
                position = try createPositionFromFEN(startpos_fen);
            },
            .setoption => {},
            .ponderhit => {},
            .stop => {},
            .position => {
                const raw_arg1 = cmd_parts.next() orelse continue;
                const arg1 = std.meta.stringToEnum(PositionArguments, raw_arg1) orelse continue;

                switch (arg1) {
                    .startpos => {
                        position = try createPositionFromFEN(startpos_fen);
                    },
                    .fen => {
                        var fen_buf: [128]u8 = undefined;
                        var fen_len: usize = 0;
                        for (0..6) |_| {
                            const tok = cmd_parts.next() orelse break;
                            if (fen_len > 0) {
                                fen_buf[fen_len] = ' ';
                                fen_len += 1;
                            }
                            @memcpy(fen_buf[fen_len..][0..tok.len], tok);
                            fen_len += tok.len;
                        }
                        position = try createPositionFromFEN(fen_buf[0..fen_len]);
                    },
                }

                const maybe_moves_kw = cmd_parts.next() orelse continue;
                if (!std.mem.eql(u8, maybe_moves_kw, "moves")) continue;
                while (cmd_parts.next()) |move_str| {
                    applyUciMove(&position, move_str) catch {};
                }
            },
            .go => {
                var perft_depth: ?usize = null;
                var depth: usize = 5;

                while (cmd_parts.next()) |arg| {
                    if (std.mem.eql(u8, arg, "depth")) {
                        if (cmd_parts.next()) |d| {
                            depth = std.fmt.parseInt(usize, d, 10) catch 6;
                        }
                    } else if (std.mem.eql(u8, arg, "perft")) {
                        if (cmd_parts.next()) |d| {
                            perft_depth = std.fmt.parseInt(usize, d, 10) catch null;
                        }
                    }
                    // movetime, wtime, btime, winc, binc, infinite: use default depth
                }

                if (perft_depth) |pd| {
                    _ = try perft(&position, pd);
                } else {
                    const best_move = try search_mod.search(&position, depth);
                    var move_buf: [5]u8 = undefined;
                    const move_str = moveToUci(best_move, &move_buf);
                    var out_buf: [20]u8 = undefined;
                    const out = try std.fmt.bufPrint(&out_buf, "bestmove {s}\n", .{move_str});
                    try stdout.writeAll(out);
                }
            },
        }
    }
}
