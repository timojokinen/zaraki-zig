const std = @import("std");
const build_options = @import("build_options");
const utils = @import("utils.zig");
const search = @import("search.zig");
const perft = @import("perft.zig").perft;
const mv = @import("move.zig");
const tt = @import("tt.zig");

const Position = @import("position.zig").Position;

const DEFAULT_TT_SIZE_MB = 16;

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
const GoArguments = enum {
    depth,
    perft,
    infinite,
    movetime,
    wtime,
    btime,
    winc,
    binc,
};

pub const UCIInterface = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    position: Position = undefined,
    tt: tt.TranspositionTable = undefined,
    searcher: search.Searcher = undefined,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) UCIInterface {
        return UCIInterface{
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn listen(self: *UCIInterface) !void {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(self.io, &stdout_buf);
        const stdout: *std.Io.Writer = &stdout_writer.interface;
        defer stdout.flush() catch {};

        var stdin_buf: [16 * 1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(self.io, &stdin_buf);
        const stdin: *std.Io.Reader = &stdin_reader.interface;

        const start_pos = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        try self.init_tt(DEFAULT_TT_SIZE_MB);
        defer self.tt.deinit();
        self.searcher = .{ .allocator = self.allocator, .tt = &self.tt, .io = self.io, .stdout = stdout };
        self.position = try self.initPositionFromFen(start_pos);

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
                    try stdout.print("id name Zaraki {s}\n", .{build_options.engine_version});
                    try stdout.writeAll("id author Timo Jokinen\n");
                    try stdout.writeAll("uciok\n");
                    try stdout.flush();
                },
                .isready => {
                    try stdout.writeAll("readyok\n");
                    try stdout.flush();
                },
                .ucinewgame => {
                    self.position = try self.initPositionFromFen(start_pos);
                },
                .setoption => {},
                .ponderhit => {},
                .stop => {
                    self.searcher.should_stop = true; // TODO: DOES NOT WORK YET, NEED SEARCHER ON WORKER THREAD
                },
                .position => {
                    const raw_arg1 = cmd_parts.next() orelse continue;
                    const arg1 = std.meta.stringToEnum(PositionArguments, raw_arg1) orelse continue;

                    // TODO: If position changes, do I reset heuristics without ucinewgame?
                    switch (arg1) {
                        .startpos => {
                            try self.position.applyFen(start_pos);
                            self.searcher.resetPerNewPosition();
                            self.searcher.pushRepetition(self.position.hash);
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
                            try self.position.applyFen(fen_buf[0..fen_len]);
                            self.searcher.resetPerNewPosition();
                            self.searcher.pushRepetition(self.position.hash);
                        },
                    }

                    const maybe_moves_kw = cmd_parts.next() orelse continue;
                    if (!std.mem.eql(u8, maybe_moves_kw, "moves")) continue;
                    while (cmd_parts.next()) |move_str| {
                        applyUciMove(&self.position, move_str) catch break;
                        self.searcher.pushRepetition(self.position.hash);
                    }
                },
                .go => {
                    var limits: search.SearchLimits = .{};

                    while (cmd_parts.next()) |arg| {
                        const go_arg = std.meta.stringToEnum(GoArguments, arg) orelse continue;
                        switch (go_arg) {
                            .depth => limits.depth = utils.parseNextInt(&cmd_parts, usize),
                            .movetime => limits.movetime_ms = utils.parseNextInt(&cmd_parts, u64),
                            .wtime => limits.wtime_ms = utils.parseNextInt(&cmd_parts, u64),
                            .btime => limits.btime_ms = utils.parseNextInt(&cmd_parts, u64),
                            .winc => limits.winc_ms = utils.parseNextInt(&cmd_parts, u64),
                            .binc => limits.binc_ms = utils.parseNextInt(&cmd_parts, u64),
                            .infinite => limits.infinite = true,
                            .perft => limits.perft = utils.parseNextInt(&cmd_parts, usize),
                        }
                    }

                    if (limits.perft) |pd| {
                        _ = try perft(self.io, &self.position, pd);
                    } else {
                        const best_move = try self.searcher.think(
                            &self.position,
                            limits,
                        );
                        var move_buf: [5]u8 = undefined;
                        const move_str = moveToUci(best_move, &move_buf);
                        try stdout.print("bestmove {s}\n", .{move_str});
                        try stdout.flush();
                    }
                },
            }
        }
    }

    fn init_tt(self: *UCIInterface, size_in_mb: usize) !void {
        const tt_size = mb_to_tt_size(size_in_mb);
        self.tt = try .init(self.allocator, tt_size);
    }

    fn initPositionFromFen(self: *UCIInterface, fen: []const u8) !Position {
        self.searcher.resetPerGame();
        const position = try Position.createFromFen(fen);
        self.searcher.pushRepetition(position.hash);
        return position;
    }
};

fn moveToUci(move: mv.Move, buf: *[5]u8) []u8 {
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

    var move_list = mv.MoveList{};
    try position.generateMoves(&move_list);
    for (move_list.moves[0..move_list.count]) |m| {
        if (m.move.from_sq != from_sq or m.move.to_sq != to_sq) continue;
        if (promo_char != 0) {
            const is_match = switch (m.move.flags) {
                .QUEEN_PROMOTION, .QUEEN_PROMOTION_CAPTURE => promo_char == 'q',
                .ROOK_PROMOTION, .ROOK_PROMOTION_CAPTURE => promo_char == 'r',
                .BISHOP_PROMOTION, .BISHOP_PROMOTION_CAPTURE => promo_char == 'b',
                .KNIGHT_PROMOTION, .KNIGHT_PROMOTION_CAPTURE => promo_char == 'n',
                else => false,
            };
            if (!is_match) continue;
        }
        try position.makeMove(m.move);
        return;
    }
    return error.MoveNotFound;
}

fn mb_to_tt_size(mb: usize) usize {
    const requested_size_in_bit = mb * 1024 * 1024 / @sizeOf(tt.TTEntry);
    return @as(u64, 1) << @as(u6, @intCast(63 - @clz(requested_size_in_bit)));
}
