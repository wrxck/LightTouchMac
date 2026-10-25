#!/bin/bash
# tests/headless/check.sh APP BASE [HELPER]: boots BASE (a prepared base) headless with HELPER through tools/headless
# (default: one tools/headless/build-helper.sh builds from this checkout against APP's emulator) on a new overlay,
# and checks that the helper outlives its first frame ring, answers its control socket, writes a PNG of the screen and
# halts. Ends with one line, PASS <summary> <log> or FAIL <first failure> <log>; exit 0 pass, 1 fail, 64 usage.
set -uo pipefail
if [ $# -lt 2 ]; then
    echo "usage: $0 'Light Touch.app' BASE [HELPER]" >&2
    exit 64
fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP=$(cd "$1" && pwd)
BASE=$(cd "$2" && pwd)
WORK=${LTM_CHECK_WORK:-$HOME/Developer/ltm-scratch.noindex/headless-check}
LOG=$WORK/check.log
rm -rf "$WORK"
mkdir -p "$WORK"
: > "$LOG"
fail() {
    LTM_APP="$APP" LTM_BASE="$BASE" LTM_RUN="$WORK/run" LTM_STATE="$WORK" "$ROOT/tools/headless/ltdev" stop >> "$LOG" 2>&1
    echo "FAIL $1 $LOG"
    exit 1
}
HELPER=${3:-}
if [ -z "$HELPER" ]; then
    "$ROOT/tools/headless/build-helper.sh" "$APP" "$WORK/helper" >> "$LOG" 2>&1 || fail "build-helper.sh"
    HELPER=$WORK/helper/Contents/MacOS/LightTouchDevice
fi
swift build -c release --package-path "$ROOT/tools/headless" >> "$LOG" 2>&1 || fail "ltm-boot build"
export LTM_APP="$APP" LTM_BASE="$BASE" LTM_HELPER="$HELPER" LTM_RUN="$WORK/run" LTM_STATE="$WORK"
LTDEV=$ROOT/tools/headless/ltdev
"$LTDEV" start >> "$LOG" 2>&1 || fail "start: $(tail -1 "$LOG")"
pid=$(cat "$WORK/run/helper.pid")
grep -q '"event":"ring"' "$WORK/run/helper.jsonl" || fail "no frame ring event"
# the pump calls the ring callback on its own queue; give it time to run past it
sleep 10
kill -0 "$pid" 2> /dev/null || fail "the helper died after its first ring"
status=$("$LTDEV" status 2>> "$LOG" | tail -1)
echo "$status" >> "$LOG"
case "$status" in *ready=1*) ;; *) fail "status: $status" ;; esac
"$LTDEV" screen "$WORK/screen.png" >> "$LOG" 2>&1 || fail "screen"
file "$WORK/screen.png" | grep -q "PNG image data" || fail "screen.png is not a PNG"
"$LTDEV" stop >> "$LOG" 2>&1
kill -0 "$pid" 2> /dev/null && fail "the helper did not halt"
echo "PASS headless helper boots, answers its control socket, writes a PNG and halts $LOG"
