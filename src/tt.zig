const std = @import("std");
const Move = @import("move.zig").Move;

pub const TranspositionTable = struct {
    entries: []TTEntry,
    mask: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_entries: usize) !TranspositionTable {
        const entries = try allocator.alloc(TTEntry, num_entries);
        @memset(entries, std.mem.zeroes(TTEntry));
        return .{
            .entries = entries,
            .allocator = allocator,
            .mask = num_entries - 1,
        };
    }

    pub fn get(self: *TranspositionTable, hash: u64) TTEntry {
        const entry = self.entries[hash & self.mask];
        if (entry.hash == hash and entry.node_type != .NONE) return entry;
        return std.mem.zeroes(TTEntry);
    }

    pub fn set(self: *TranspositionTable, hash: u64, entry: TTEntry) void {
        self.entries[hash & self.mask] = entry;
    }

    pub fn deinit(self: *TranspositionTable) void {
        self.allocator.free(self.entries);
    }

    pub fn clear(self: *TranspositionTable) void {
        @memset(self.entries, std.mem.zeroes(TTEntry));
    }
};

pub const NodeType = enum(u2) { NONE, EXACT, UPPERBOUND, LOWERBOUND };

pub const TTEntry = struct {
    hash: u64,
    hash_move: Move,
    depth: u8,
    score: i32,
    node_type: NodeType = .NONE,
};
