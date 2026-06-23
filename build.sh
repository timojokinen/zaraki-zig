#!/usr/bin/env sh
set -eu

ENGINE_NAME="zaraki_engine"
RELEASE_DIR="releases"

usage() {
    cat <<EOF
Usage:
  ./build.sh release <version> [zig build options...]

Examples:
  ./build.sh release qdelta
  ./build.sh release v0.2
  ./build.sh release baseline -Dtarget=x86_64-linux-gnu

Creates:
  ${RELEASE_DIR}/${ENGINE_NAME}-<version>
EOF
}

if [ "$#" -eq 0 ]; then
    usage
    exit 1
fi

cmd="$1"
shift

case "$cmd" in
    release)
        if [ "$#" -lt 1 ]; then
            usage
            exit 1
        fi

        version="$1"
        shift

        case "$version" in
            *[!A-Za-z0-9._-]* | "" | .* | *..* | */*)
                echo "Invalid version: $version" >&2
                echo "Use only letters, numbers, dot, underscore, and dash." >&2
                exit 1
                ;;
        esac

        tmp_prefix="$(mktemp -d "${TMPDIR:-/tmp}/zaraki-release.XXXXXX")"
        trap 'rm -rf "$tmp_prefix"' EXIT HUP INT TERM

        zig build -Doptimize=ReleaseFast -Dengine_version="$version" -p "$tmp_prefix" "$@"

        mkdir -p "$RELEASE_DIR"
        cp "$tmp_prefix/bin/$ENGINE_NAME" "$RELEASE_DIR/$ENGINE_NAME-$version"
        chmod +x "$RELEASE_DIR/$ENGINE_NAME-$version"

        echo "Built $RELEASE_DIR/$ENGINE_NAME-$version"
        echo "Cutechess engine cmd: ./$RELEASE_DIR/$ENGINE_NAME-$version"
        ;;
    help | -h | --help)
        usage
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        usage
        exit 1
        ;;
esac
