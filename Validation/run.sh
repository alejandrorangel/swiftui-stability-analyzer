#!/bin/sh
# Runs StabilityLab on a simulator, then compares the measured body counts with the analyzer's predictions.
#
#   Validation/run.sh                          the only booted simulator
#   Validation/run.sh "iPhone 17"              a simulator by name or UDID
#   Validation/run.sh "My iPad" TEAM_ID        a physical device, signed with your team
#
# Requires ios-cli 0.4.1+ (https://github.com/alejandrorangel/ios-cli). Exits 1 when a prediction disagrees.
# A device build registers dev.stability.StabilityLab in the team you pass: use a team you own.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAB="$ROOT/Validation/StabilityLab"
DEVICE=${1:-}
TEAM=${2:-}
OUT=$(mktemp -d)

swift build --package-path "$ROOT" --product swiftui-stability >/dev/null
ANALYZER="$(swift build --package-path "$ROOT" --show-bin-path)/swiftui-stability"

# Runs an ios-cli command with the device (and, for build/run, the team) when given.
ios_cmd() {
    sub=$1; shift
    set -- "$sub" "$@"
    if [ -n "$DEVICE" ]; then set -- "$@" --device "$DEVICE"; fi
    if [ -n "$TEAM" ] && [ "$sub" != logs ]; then set -- "$@" --team "$TEAM"; fi
    ios "$@"
}

cd "$LAB"
ios_cmd build --scheme StabilityLab >/dev/null
ios_cmd run --scheme StabilityLab --no-build >/dev/null
ios_cmd logs --bundle-id dev.stability.StabilityLab --launch --duration 8 \
    | sed -n 's/.*STABILITY_LAB_RESULT //p' | head -1 > "$OUT/result.json"
[ -s "$OUT/result.json" ] || { echo "No result from the lab app (see ios logs)." >&2; exit 2; }

"$ANALYZER" analyze "$LAB/StabilityLab" --json > "$OUT/analyze.json"
python3 -I "$ROOT/Validation/compare.py" "$OUT/result.json" "$OUT/analyze.json"
