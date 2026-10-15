#!/bin/sh
# Builds a release `swiftui-stability` and installs it for everyday use (and for agent sessions).
#
#   scripts/install.sh            install to ~/.local (binary in ~/.local/bin, on PATH)
#   scripts/install.sh --skill    also install the agent skill into ~/.claude/skills/swiftui-stability
#   PREFIX=/opt/swiftui-stability scripts/install.sh
#
# Re-run to update. Layout: $PREFIX/share/swiftui-stability/swiftui-stability, with
# $PREFIX/bin/swiftui-stability -> ../share/swiftui-stability/swiftui-stability.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${PREFIX:-"$HOME/.local"}
SHARE="$PREFIX/share/swiftui-stability"
BIN="$PREFIX/bin"

echo "Building release…"
swift build --package-path "$ROOT" -c release --product swiftui-stability
PRODUCTS=$(swift build --package-path "$ROOT" -c release --show-bin-path)

mkdir -p "$SHARE" "$BIN"
cp "$PRODUCTS/swiftui-stability" "$SHARE/swiftui-stability.new"
mv "$SHARE/swiftui-stability.new" "$SHARE/swiftui-stability"
ln -sf "$SHARE/swiftui-stability" "$BIN/swiftui-stability"
echo "Installed swiftui-stability $("$BIN/swiftui-stability" --version) → $BIN/swiftui-stability"

if [ "${1:-}" = "--skill" ]; then
    SKILLS=${CLAUDE_SKILLS_DIR:-"$HOME/.claude/skills"}
    rm -rf "$SKILLS/swiftui-stability"
    mkdir -p "$SKILLS"
    cp -R "$ROOT/skills/swiftui-stability" "$SKILLS/"
    echo "Installed the swiftui-stability skill → $SKILLS/swiftui-stability"
fi

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Note: $BIN isn't on your PATH; add it to use \`swiftui-stability\` directly." ;;
esac
