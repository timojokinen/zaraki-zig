const std = @import("std");
const search = @import("search.zig");
const Move = @import("move.zig").Move;

fn nodeTypeBonus(node_type: NodeType) i32 {
    return switch (node_type) {
        .EXACT => 4,
        .LOWERBOUND => 2,
        .UPPERBOUND => 0,
        .NONE => unreachable,
    };
}

fn shouldReplace(prev_entry: TTEntry, new_entry: TTEntry) bool {
    if (prev_entry.node_type == .NONE) return true;

    if (prev_entry.hash == new_entry.hash) {
        return new_entry.depth >= prev_entry.depth;
    }

    // Replace stale entries, but only if the new entry is not much shallower.
    if (prev_entry.age != new_entry.age and new_entry.depth + 2 >= prev_entry.depth) {
        return true;
    }

    // Same age: prefer depth.
    if (new_entry.depth > prev_entry.depth) {
        return true;
    }

    // Same depth: prefer exact/lower over upper.
    if (new_entry.depth == prev_entry.depth) {
        return nodeTypeBonus(new_entry.node_type) > nodeTypeBonus(prev_entry.node_type);
    }

    return false;
}

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
        const prev_entry = (self.entries[hash & self.mask]);
        if (!shouldReplace(prev_entry, entry)) return;

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

pub const TTEntry = packed struct(u110) {
    hash: u64,
    hash_move: Move,
    depth: u8,
    score: i16,
    node_type: NodeType = .NONE,
    age: u4,
};
