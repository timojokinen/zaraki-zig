const std = @import("std");
const attacks = @import("attacks.zig");
const utils = @import("utils.zig");
const tables = @import("tables.zig");

var prng = std.Random.Xoshiro256.init(0x9e37_79b9_7f4a_7c15);

fn edges(sq: u6) u64 {
    return ((utils.maskFile(0) | utils.maskFile(63)) & ~utils.maskFile(sq)) | ((utils.maskRank(0) | utils.maskRank(63)) & ~utils.maskRank(sq));
}

pub fn initMagic(square: u6, bishop: bool, offset: *usize, table: *[tables.SLIDER_TABLE_SIZE]u64) tables.SliderMetadata {
    const att_mask: u64 = (if (bishop) attacks.bishopAttacks(square, 0) else attacks.rookAttacks(square, 0)) & ~edges(square);
    const relevant_bits: u6 = @intCast(@popCount(att_mask));
    const perm_count: usize = @as(usize, 1) << relevant_bits;
    const shift: u6 = @intCast(@as(usize, 64) -| relevant_bits);

    var blocker_configurations: [4096]u64 = undefined;
    var attack_table: [4096]u64 = undefined;

    var n: u64 = 0;
    var idx: usize = 0;
    while (true) {
        blocker_configurations[idx] = n;
        attack_table[idx] = if (bishop) attacks.bishopAttacks(square, n) else attacks.rookAttacks(square, n);

        n = (n -% att_mask) & att_mask;
        if (n == 0) break;
        idx += 1;
    }

    const rand = prng.random();
    var magic: u64 = if (bishop) BISHOP_MAGICS[square] else ROOK_MAGICS[square];

    while (true) {
        if (magic == 0) {
            const candidate = rand.int(u64) & rand.int(u64) & rand.int(u64);
            if (!verifyCandidate(candidate, att_mask)) continue;
            magic = candidate;
        }

        var failure = false;
        var used_attacks: [4096]u64 = std.mem.zeroes([4096]u64);

        for (0..perm_count) |i| {
            const hash_idx = calculateHashIdx(magic, blocker_configurations[i], shift);

            if (used_attacks[hash_idx] == 0) {
                used_attacks[hash_idx] = attack_table[i];
            } else if (used_attacks[hash_idx] != attack_table[i]) {
                failure = true;
                break;
            }
        }

        if (failure) {
            magic = 0;
            continue;
        }

        const found_magic: tables.SliderMetadata = .{ .magic = magic, .mask = att_mask, .shift = shift, .offset = offset.* };

        for (0..perm_count) |p_idx| {
            table[offset.* + p_idx] = used_attacks[p_idx];
        }

        offset.* += perm_count;
        return found_magic;
    }
}

pub fn calculateHashIdx(magic: u64, occ: u64, shift: u6) usize {
    return @intCast((occ *% magic) >> shift);
}

fn verifyCandidate(magic: u64, attack_mask: u64) bool {
    return @popCount((attack_mask *% magic) & 0xff00000000000000) >= 6;
}

const BISHOP_MAGICS: [64]u64 = .{
    11547247041092684304,
    3467772829909942784,
    11300798797455616,
    145264186585270276,
    144697998629666817,
    9228440794585628746,
    1297127058863816712,
    1144628147396632,
    17747358778385,
    17871392735296,
    11565331977972547588,
    90074234553896962,
    4415763292192,
    5767423441067081760,
    1153207381950734352,
    6605693322248,
    2251817539338753,
    671037461189101824,
    616153399175479552,
    149187252429390465,
    562967435411464,
    9323014179180847120,
    18577349553692672,
    2308182787842248710,
    369444737930953740,
    6900535010793476,
    1226192976796090576,
    25055946187473024,
    1300494111358328832,
    282575059812488,
    10376575366545540098,
    5910130240646587393,
    299136956538892,
    289360691830329408,
    2815918082162752,
    612491750493651072,
    4756962565930877184,
    9225663698261282818,
    37163568218639488,
    19149783851728961,
    9224515548342128672,
    144683293669332996,
    5197224493617250560,
    283602065536,
    2738752627771704320,
    3539864501287404674,
    9516686572062966016,
    282583246121088,
    564329175908866,
    5190434888822554624,
    153122529199296592,
    4641381673904373760,
    3467772005678456875,
    1188959235300426041,
    10416861708751503370,
    1190151002716643840,
    443060309488312354,
    612491860161677344,
    577595480553824774,
    2305844117323908096,
    9403799697027662336,
    49557205401733185,
    16429166633653117184,
    580968818854201632,
};

const ROOK_MAGICS: [64]u64 = .{
    36031565671776256,
    4773833198272651264,
    72075323667185672,
    180152785751343236,
    144150406841241604,
    144117389263638536,
    288239378705221764,
    72076285746643522,
    4612671182997553250,
    2326250219911782400,
    5188287576947040256,
    5336906330290524160,
    2595480794625475600,
    73324248621384192,
    141287277723904,
    32088149496824068,
    612489824204496897,
    36284957491456,
    108157859849572616,
    6057483885703335936,
    141287378387968,
    4756927381321613376,
    4611968597210956288,
    1409573973950545,
    22588369028522112,
    576495937753452544,
    288265562672332928,
    562992907296784,
    5315373479539771392,
    9368617525031600256,
    2324420633636634880,
    72075744569794628,
    13835199067673591986,
    9077638874275844,
    9233577704085791360,
    36178332789772292,
    18295942289557504,
    4400202383872,
    1297601910445967361,
    1666480874563,
    162132062634082336,
    18014570576683010,
    9223653649308516369,
    146367056617439244,
    292171095090790408,
    563019210032128,
    17600776241672,
    9077749055495,
    70377879372160,
    35185445863808,
    576744495559754496,
    2251834442154112,
    2251834240565376,
    9367489426101633152,
    144117456382198784,
    14141866330743382528,
    1152992011066802433,
    15078069290668165698,
    36381877691484929,
    612494089103868169,
    5820339706001625094,
    9288691411845633,
    11330469740300292,
    1441156280970911810,
};
