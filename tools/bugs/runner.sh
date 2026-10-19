#!/usr/bin/env bash
# The fix runner (contract/bug-pipeline-2026-10-18.md § Runner). launchd starts this every 5 minutes
# (tools/bugs/install.sh). It costs nothing unless there is work:
#   - an open S1 → a headless Claude Code run of the fix-bugs skill for S1s, right away;
#   - the 08:00 and 18:00 windows → one run for everything open (most severe first), once per window.
# One run at a time (a lock), each with a spending cap; the transcript goes to ~/Library/Logs/Table1Bugs/.
#   tools/bugs/runner.sh            what launchd runs
#   tools/bugs/runner.sh --dry      say what it would do, run nothing
#   tools/bugs/runner.sh --now      run for everything open now, whatever the time
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
REPO=$(cd "$(dirname "$0")/../.." && pwd)
STATE="$HOME/.table1-bugs"; LOGS="$HOME/Library/Logs/Table1Bugs"; LOCK="$STATE/run.lock"
mkdir -p "$STATE" "$LOGS"
S1_BUDGET=${T1_BUGS_S1_BUDGET:-15}      # USD per S1 run
WINDOW_BUDGET=${T1_BUGS_WINDOW_BUDGET:-40}
MODE=${1:-}

[ -f "$STATE/paused" ] && { [ "$MODE" = --dry ] && echo "paused ($STATE/paused)"; exit 0; }

# A lock older than 4 hours belongs to a run that died.
if ! mkdir "$LOCK" 2>/dev/null; then
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +240 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

status=$(python3 "$REPO/tools/bugs/bugs.py" status --json 2>>"$LOGS/runner.err") || exit 0
open_s1=$(jq -r '.open_s1 // 0' <<<"$status")
open_total=$(jq -r '.open_total // 0' <<<"$status")

hour=$(date +%H); today=$(date +%F)
window=""
if [ "$hour" -ge 18 ]; then window="$today-pm"; elif [ "$hour" -ge 8 ]; then window="$today-am"; fi
last_window=$(cat "$STATE/last-window" 2>/dev/null || true)

max=""; budget=0
if [ "$MODE" = --now ]; then
  max=S4; budget=$WINDOW_BUDGET
elif [ "$open_s1" -gt 0 ]; then
  max=S1; budget=$S1_BUDGET
elif [ -n "$window" ] && [ "$window" != "$last_window" ]; then
  [ "$MODE" = --dry ] || echo "$window" >"$STATE/last-window"
  [ "$open_total" -gt 0 ] && { max=S4; budget=$WINDOW_BUDGET; }
fi

if [ "$MODE" = --dry ]; then
  echo "open S1: $open_s1, open: $open_total, window: ${window:-none} (last ${last_window:-none}) → ${max:-nothing to do}"
  exit 0
fi
[ -z "$max" ] && exit 0

log="$LOGS/$(date +%Y%m%d-%H%M%S)-$max.log"
echo "$(date '+%F %T') run max=$max budget=\$$budget open_s1=$open_s1 open=$open_total" >>"$LOGS/runner.log"
cd "$REPO" || exit 1
T1_RUNNER_NAME="runner-$(date +%H%M)" claude -p "/fix-bugs $max" \
  --permission-mode auto --max-budget-usd "$budget" --output-format text >"$log" 2>&1
echo "$(date '+%F %T') done max=$max exit=$? log=$log" >>"$LOGS/runner.log"
