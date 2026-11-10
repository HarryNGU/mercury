#!/bin/zsh
# Runs Mercury's automatic checks against a freshly built app, without installing it or touching the copy
# in ~/Applications: the --unittests logic checks, then the offscreen hooks (chat, panel, keyboard focus,
# welcome tour, problem report), checking the lines each one logs. Nothing shows on screen and no saved
# chats or settings are read or changed. Pictures the hooks draw are kept in a temporary folder to look at.
#
#   tools/run-tests.sh            build (NO_INSTALL=1 ./build.sh), then test build/Mercury.app
#   tools/run-tests.sh --no-build test the app already in build/
set -uo pipefail
cd "$(dirname "$0")/.."

LOG=~/Library/Logs/Bubble.log
if [[ -f $LOG ]] && grep -a "start requested\|writer finished" $LOG | tail -1 | grep -q "start requested"; then
  echo "Mercury is recording right now. Run the tests when it has finished."; exit 2
fi
if [[ ${1:-} != --no-build ]]; then
  NO_INSTALL=1 ./build.sh > build/test-build.log 2>&1 || { echo "Build failed, see build/test-build.log"; exit 1; }
fi
BIN=build/Mercury.app/Contents/MacOS/Mercury
[[ -x $BIN ]] || { echo "No app in build/. Run without --no-build first."; exit 1; }

OUT=$(mktemp -d -t mercury-tests)
FAILED=0
pass() { print -r -- "  ok    $1"; }
fail() { print -r -- "  FAIL  $1"; FAILED=1; }

# Runs one hook (stopping it after 90 seconds) and keeps the log lines it wrote.
hook() {
  local name=$1; shift
  local before=$(wc -c < $LOG 2>/dev/null || echo 0)
  perl -e 'alarm 90; exec @ARGV' "$BIN" "$@" > /dev/null 2>&1
  local code=$?
  tail -c +$((before + 1)) $LOG | grep -a "$name:" | sed -E 's/^[0-9-]+ [0-9:]+ \+0000 //' > "$OUT/$name.log"
  (( code == 0 )) || fail "$name stopped with code $code"
}
expect() {  # expect <hook> <text it must have logged>
  grep -qF -- "$2" "$OUT/$1.log" && pass "$1: $2" || fail "$1: missing '$2'"
}

echo "Logic checks"
"$BIN" --unittests | sed 's/^/  /'
(( ${pipestatus[1]} == 0 )) || FAILED=1

echo "Offscreen hooks (pictures in $OUT)"
VIDEO=$OUT/clip.mp4
command -v ffmpeg > /dev/null && ffmpeg -loglevel error -f lavfi -i testsrc=size=640x360:rate=30 -t 2 -pix_fmt yuv420p "$VIDEO"

hook chatshot --chatshot "$OUT/chat.png"
expect chatshot "pinch outside used=false open=false, pinch on picture used=true open=true"
expect chatshot "fit button 100%"
expect chatshot "closed true"

hook panelshot --panelshot "$OUT/panel.png" "$VIDEO"
for s in "400.0, 420.0" "500.0, 420.0" "640.0, 500.0" "1500.0, 900.0"; do expect panelshot "asked ($s) got ($s)"; done
expect panelshot "window held at 500x400 -> (500.0, 400.0)"
expect panelshot "window held at 900x700 -> (900.0, 700.0)"
expect panelshot "window measured again after letting go"

hook focustest --focustest
expect focustest "Bash ls -la ~/Desktop -> controls Mac false"
expect focustest "mcp__computer-use__left_click  -> controls Mac true"
expect focustest "Claude driving: key false, visible true, can take keyboard false"
expect focustest "asked for the keyboard while locked, key false"

hook tourshot --tourshot "$OUT/tour.png" --onboard 2
expect tourshot "tourshot: wrote"
[[ -s $OUT/tour.png ]] && pass "tourshot: picture drawn" || fail "tourshot: no picture"

hook reportshot --reportshot "$OUT/report.png"
expect reportshot 'folder holds ["Mercury log.txt", "Report.txt", "Screenshot.png"]'
[[ -s $OUT/report.png && -s $OUT/report-draw.png ]] && pass "reportshot: pictures drawn" || fail "reportshot: pictures missing"

if (( FAILED )); then echo "Some checks failed. Hook logs are in $OUT"; exit 1; fi
echo "All checks passed."
