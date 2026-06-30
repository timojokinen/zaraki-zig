#!/usr/bin/env sh
set -eu

usage() {
    cat <<EOF
Usage:
  ./cutechess.sh <engine-1> <engine-2> [engine-2-elo]

Examples:
  ./cutechess.sh ./releases/zaraki_engine-candidate /usr/bin/stockfish 2000
  ./cutechess.sh ./releases/zaraki_engine-candidate ./releases/zaraki_engine-basic_eval

When engine-2-elo is supplied, engine 2 receives:
  UCI_LimitStrength=true
  UCI_Elo=<engine-2-elo>
EOF
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    usage >&2
    exit 2
fi

engine_1=$1
engine_2=$2
engine_2_elo=${3-}

check_engine() {
    engine=$1
    case "$engine" in
        */*)
            if [ ! -x "$engine" ]; then
                echo "Engine is not executable: $engine" >&2
                exit 1
            fi
            ;;
        *)
            if ! command -v "$engine" >/dev/null 2>&1; then
                echo "Engine not found in PATH: $engine" >&2
                exit 1
            fi
            ;;
    esac
}

engine_name() {
    name=${1##*/}
    case "$name" in
        zaraki_engine-*) name=${name#zaraki_engine-} ;;
    esac
    printf '%s' "$name"
}

check_engine "$engine_1"
check_engine "$engine_2"

opening_file=book.pgn

if [ ! -f "$opening_file" ]; then
    echo "Opening book not found: $PWD/$opening_file" >&2
    exit 1
fi

first_opening=$(awk 'NF { sub(/\r$/, ""); print; exit }' "$opening_file")
if [ -z "$first_opening" ]; then
    echo "Opening book is empty: $PWD/$opening_file" >&2
    exit 1
fi

# EPD records begin with a FEN board and side-to-move field. PGN normally
# begins with a tag (or movetext), so do not rely on the filename extension.
if printf '%s\n' "$first_opening" | awk '
    NF >= 4 && index($1, "/") && ($2 == "w" || $2 == "b") { found = 1 }
    END { exit !found }
'; then
    opening_format=epd
else
    opening_format=pgn
fi

if [ -n "$engine_2_elo" ]; then
    case "$engine_2_elo" in
        *[!0-9]* | "")
            echo "Engine Elo must be a positive integer: $engine_2_elo" >&2
            exit 2
            ;;
    esac
fi

name_1=$(engine_name "$engine_1")
name_2=$(engine_name "$engine_2")
if [ -n "$engine_2_elo" ]; then
    name_2="${name_2}-${engine_2_elo}"
fi

stderr_1="$PWD/${name_1}-stderr.log"
stderr_2="$PWD/${name_2}-stderr.log"
pgn_out="${name_1}-vs-${name_2}.pgn"

set -- cutechess-cli \
    -engine name="$name_1" cmd="$engine_1" proto=uci stderr="$stderr_1" \
    -engine name="$name_2" cmd="$engine_2" proto=uci stderr="$stderr_2"

if [ -n "$engine_2_elo" ]; then
    set -- "$@" \
        option.UCI_LimitStrength=true \
        option.UCI_Elo="$engine_2_elo"
fi

set -- "$@" \
    -each tc=10+0.1 \
    -openings file="$opening_file" format="$opening_format" order=random \
    -games 2 \
    -rounds 500 \
    -repeat \
    -sprt elo0=0 elo1=5 alpha=0.05 beta=0.05 \
    -concurrency 16 \
    -pgnout "$pgn_out"

echo "Engine 1: $name_1 ($engine_1)"
echo "Engine 2: $name_2 ($engine_2)"
echo "Openings: $opening_file ($opening_format)"
echo "PGN:      $pgn_out"

exec "$@"
