const std = @import("std");

const SEED: u64 = 8730124647094862553;

var piece_keys: [12][64]u64 = undefined;
var castling_rights_keys: [16]u64 = undefined;
var black_key: u64 = undefined;
var ep_keys: [8]u64 = undefined;

pub fn initZobristKeys() void {
    var prng = std.Random.SplitMix64.init(SEED);
    for (0..12) |piece_idx| {
        for (0..64) |sq| {
            piece_keys[piece_idx][sq] = prng.next();
        }
    }

    black_key = prng.next();

    for (0..16) |castling_right_idx| {
        castling_rights_keys[castling_right_idx] = prng.next();
    }

    for (0..8) |ep_idx| {
        ep_keys[ep_idx] = prng.next();
    }
}
