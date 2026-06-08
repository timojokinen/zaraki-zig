const Position = @import("position.zig").Position;
const PieceType = @import("piece.zig").PieceType;
const Color = @import("utils.zig").Color;

fn materialScore(pos: *const Position, offset: usize) i32 {
    const pawns: u16 = @popCount(pos.bbs[@intFromEnum(PieceType.Pawn) + offset]);
    const knights: u16 = @popCount(pos.bbs[@intFromEnum(PieceType.Knight) + offset]);
    const bishops: u16 = @popCount(pos.bbs[@intFromEnum(PieceType.Bishop) + offset]);
    const rooks: u16 = @popCount(pos.bbs[@intFromEnum(PieceType.Rook) + offset]);
    const queens: u16 = @popCount(pos.bbs[@intFromEnum(PieceType.Queen) + offset]);
    return @as(i32, (pawns * 100) + (knights * 300) + (bishops * 300) + (rooks * 500) + (queens * 900));
}

pub fn eval(pos: *const Position) i32 {
    const ally_offset: usize = if (pos.board_state.side_to_move == .White) 0 else 6;
    const opp_offset: usize = if (pos.board_state.side_to_move == .White) 6 else 0;
    return materialScore(pos, ally_offset) - materialScore(pos, opp_offset);
}
