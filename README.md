# Zaraki

![Zaraki header](header.png)

Zaraki is a single-threaded UCI chess engine written in Zig. It uses a
handcrafted evaluation and a fairly traditional alpha-beta search. The engine
is playable, but it is still under active development and does not have an
official rating yet. My current estimation is around 2600.

I am a beginner in both chess programming and Zig. Zaraki is a learning project.

## Building

Zaraki currently builds with Zig 0.16.0.

```bash
zig build -Doptimize=ReleaseFast
```

The executable is written to `zig-out/bin/zaraki_engine`. A debug build is just:

```bash
zig build
```

Release builds can include a version in the UCI engine name:

```bash
zig build -Doptimize=ReleaseFast -Dengine_version=v0.1.0
```

## Running it

Zaraki does not include a graphical interface. Add the executable as a UCI
engine in Cute Chess, Arena, Banksia, or another chess GUI.

You can also talk to it directly:

```text
$ ./zig-out/bin/zaraki_engine
uci
isready
position startpos moves e2e4 e7e5
go depth 8
```

The engine understands `startpos` and FEN positions, fixed-depth searches,
`movetime`, and the usual clock and increment arguments (`wtime`, `btime`,
`winc`, and `binc`).

## What's implemented

The board is represented with bitboards and moves are packed into 16 bits.
Move generation handles checks, pins, castling, promotion, and en passant.
Positions support incremental make/unmake, null moves, incremental Zobrist
hashing, threefold repetition, and the fifty-move rule.

The search currently includes:

- Iterative deepening negamax with alpha-beta pruning
- Principal variation search and aspiration windows
- Quiescence search with stand pat, SEE pruning, and delta pruning
- A transposition table with exact, upper, and lower bounds
- Depth-, age-, and bound-aware transposition-table replacement
- Null-move pruning, late-move reductions, and check extensions
- Hash moves, MVV-LVA/SEE captures, killers, history, and countermoves
- Mate-score normalization and selective-depth reporting
- Basic clock management with soft and hard time limits

Evaluation is tapered between middlegame and endgame scores. It uses PeSTO
material and piece-square tables, mobility, a bishop-pair bonus, a simple pawn
shield term, and a tempo bonus. It is intentionally still small enough to
understand and change without needing a training pipeline.

## Testing

Run the Zig tests with:

```bash
zig build test
```

Perft is available through UCI and is the main move-generation correctness
check:

```text
position startpos
go perft 6
```

For strength testing I use paired games with an opening suite so that both
engines play each opening from both colors.

## Current limitations

- Search is single-threaded.
- The transposition table is fixed at 16 MiB; UCI `setoption` is not implemented yet.
- Search runs on the UCI thread, so `stop` cannot interrupt an active search yet.
- Pondering is not implemented.
- There are no tablebases or NNUE evaluation.
- Automated test coverage is still small; perft and engine matches do most of
  the practical validation.

## Code map

- [`src/position.zig`](src/position.zig): position state, legal moves, and
  make/unmake
- [`src/search.zig`](src/search.zig): iterative deepening, alpha-beta, pruning,
  and time management
- [`src/movepick.zig`](src/movepick.zig): move ordering and static exchange
  evaluation
- [`src/eval.zig`](src/eval.zig): handcrafted tapered evaluation
- [`src/tt.zig`](src/tt.zig): transposition table
- [`src/uci.zig`](src/uci.zig): UCI command loop
- [`src/perft.zig`](src/perft.zig): perft driver

## Acknowledgements

I have learned a great deal from these projects and resources:

- The [Chess Programming Wiki](https://www.chessprogramming.org/Main_Page),
- [Avalanche](https://github.com/SnowballSH/Avalanche), an open-source chess
  engine written in Zig and a useful example of chess-engine ideas expressed in
  the language
- [Stockfish](https://github.com/official-stockfish/Stockfish), both as a
  reference implementation and as an example of how modern engine techniques
  fit together

## AI disclosure

The header image was generated with an AI image tool. I also use AI tools to
help me understand chess-programming and Zig concepts, review problems, and
debug ideas. Zaraki remains an author-led project: its design and source are
manually authored, reviewed, tested, and maintained by me. Some targeted code and
documentation changes have been made with AI assistance.

## Releases

The release workflow is triggered by tags beginning with `v`.

Tagged builds are configured for Linux x86-64 and ARM64, Windows x86-64, and
macOS on Intel and Apple Silicon.
