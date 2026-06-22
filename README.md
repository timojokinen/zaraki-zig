# Zaraki

![Zaraki README Header](header.png)

Bitboard chess engine in Zig.

The code is currently a small single-threaded UCI engine with legal move generation, a standard alpha-beta search stack, incremental make/unmake, and a basic tapered PST evaluation. Most implementation choices are recognizable from conventional CPW-style engines.

## Status

- Language: Zig
- Protocol: UCI
- Search model: single-threaded negamax
- Evaluation: tapered material + PST

## Implemented Techniques

### Board Representation

- Bitboards for piece sets
- Incremental make/unmake
- Null move make/unmake
- Incremental Zobrist hashing
- FEN parsing
- Compact 16-bit move encoding

### Search

- Negamax alpha-beta
- Iterative deepening
- Aspiration windows
- Principal variation tracking
- Quiescence search with standpat, SEE Pruning
- Transposition table
- TT exact / lower-bound / upper-bound node types, always replace
- Hash move ordering
- Null move pruning
- Late move reductions
- PVS-style zero-window search on later moves
- Check extension
- Mate score normalization for TT storage
- Basic time-based stop check during node polling

### Move Ordering

- Hash move
- Queen promotions prioritized
- Capture ordering with MVV-LVA
- SEE-based capture discrimination
- Killer heuristic
- History heuristic
- Selection-sort style pick-next move loop

### Evaluation

- PeSTO-style tapered PST evaluation
- Middlegame / endgame interpolation by phase

### Validation / Utility

- Perft through UCI: `go perft N`
- UCI position parsing for `startpos` and `fen`
- PGN files in repo root that appear to be local testing artifacts

## Not Implemented / Current Limits

These are visible from the current code and matter if you plan to extend the engine:

- No multithreading
- No NNUE
- No TT replacement policy beyond direct overwrite
- `setoption` is parsed but not implemented
- `stop` is acknowledged in UCI, but the code explicitly notes it does not work properly yet because search is not on a worker thread
- Time management is intentionally simple: roughly `time_left / 30 + increment`

## Repository Layout

- [src/search.zig](/home/archbird/code/vanta-zig/src/search.zig): main search, quiescence, PV, TT usage, pruning/reduction logic
- [src/movepick.zig](/home/archbird/code/vanta-zig/src/movepick.zig): move scoring, MVV-LVA, SEE, killer/history ordering
- [src/position.zig](/home/archbird/code/vanta-zig/src/position.zig): bitboards, legal move generation, make/unmake, null move, hash updates
- [src/attacks.zig](/home/archbird/code/vanta-zig/src/attacks.zig): primitive attack generation, x-ray helpers
- [src/tables.zig](/home/archbird/code/vanta-zig/src/tables.zig): startup table construction for attack lookups, `squares_between`, LMR table
- [src/eval.zig](/home/archbird/code/vanta-zig/src/eval.zig): tapered PST evaluation
- [src/tt.zig](/home/archbird/code/vanta-zig/src/tt.zig): transposition table
- [src/uci.zig](/home/archbird/code/vanta-zig/src/uci.zig): UCI loop, command parsing, time budgeting
- [src/perft.zig](/home/archbird/code/vanta-zig/src/perft.zig): divide-style perft output
- [src/zobrist.zig](/home/archbird/code/vanta-zig/src/zobrist.zig): deterministic Zobrist key init

## Build Requirements

- Zig `0.16.0` works in this repository

If you want the least friction, use a recent Zig 0.16 toolchain.

## Build

Debug build:

```bash
zig build
```

Optimized build:

```bash
zig build -Doptimize=ReleaseFast
```

The installed executable is written under `zig-out/bin/zaraki_engine`.

## Run

Run directly through the build system:

```bash
zig build run
```

Run optimized:

```bash
zig build -Doptimize=ReleaseFast run
```

Run the installed binary:

```bash
./zig-out/bin/zaraki_engine
```

On startup the engine prints:

```text
Zaraki 0.1 by Timo Jokinen
```

## Tests

Run the Zig test steps:

```bash
zig build test
```

At the moment this repository does not contain much in the way of explicit unit-test coverage, so `perft` is the main built-in correctness tool.

## Notes for Engine Developers

- The transposition table size defaults to 16 MB in the UCI front-end.
- TT entry count is rounded down to a power of two.
- The evaluation is intentionally simple, so search changes are relatively easy to observe in isolation.
- The move generator is already doing the nontrivial legality work: pins, checks, castling, and en passant edge cases.

