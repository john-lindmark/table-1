#!/usr/bin/env bash
# The fix runner (contract/bug-pipeline-2026-10-18.md § Runner). It costs nothing unless there is work:
#   - an open S1 → a headless Claude Code run of the fix-bugs skill for S1s, right away;
#   - the 08:00 and 18:00 windows → one run for everything open (most severe first), once per window.
# One run at a time (a lock), each with a spending cap; the transcript goes to ~/Library/Logs/Table1Bugs/.
#
# launchd jobs can't read ~/Documents (macOS privacy, even with Full Disk Access for bash), so install.sh copies
# this script and bugs.py to ~/.table1-bugs/ and launchd runs `--poll` from there every 5 minutes. When there is
# work, the poll opens ~/.table1-bugs/run.command in Terminal (in the background), which can read the repo.
#   tools/bugs/runner.sh            decide and run here (by hand)
#   tools/bugs/runner.sh --dry      say what it would do, run nothing
#   tools/bugs/runner.sh --now      run for everything open now, whatever the time
#   runner.sh --poll                launchd: decide, then hand the run to Terminal
#   runner.sh --run S1|S4           run now at that level (what Terminal runs)
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
STATE="$HOME/.table1-bugs"; LOGS="$HOME/Library/Logs/Table1Bugs"; LOCK="$STATE/run.lock"
mkdir -p "$STATE" "$LOGS"
MODE=${1:-}
if [ "$MODE" = --poll ]; then
  REPO=$(cat "$STATE/repo"); BUGS="$STATE/bugs.py"
else
  REPO=$(cd "$(dirname "$0")/../.." && pwd); BUGS="$REPO/tools/bugs/bugs.py"
fi
S1_BUDGET=${T1_BUGS_S1_BUDGET:-15}      # USD per S1 run
WINDOW_BUDGET=${T1_BUGS_WINDOW_BUDGET:-40}

[ -f "$STATE/paused" ] && { [ "$MODE" = --dry ] && echo "paused ($STATE/paused)"; exit 0; }

# A lock older than 4 hours belongs to a run that died.
locked() { [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin +240 2>/dev/null)" ]; }

run() {  # run S1|S4: the headless fix-bugs run, under the lock
  local max=$1 budget=$WINDOW_BUDGET
  [ "$max" = S1 ] && budget=$S1_BUDGET
  locked && exit 0
  rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  local log; log="$LOGS/$(date +%Y%m%d-%H%M%S)-$max.log"
  echo "$(date '+%F %T') run max=$max budget=\$$budget" >>"$LOGS/runner.log"
  cd "$REPO" || exit 1
  # The runner secret goes to bugs.py through the environment: the Claude run never reads the Keychain itself.
  T1_BUG_RUNNER_SECRET=$(security find-generic-password -s table1-bug-runner -w 2>/dev/null) || {
    echo "$(date '+%F %T') no runner secret in the Keychain (bugs.py init-secret)" >>"$LOGS/runner.log"; exit 1; }
  export T1_BUG_RUNNER_SECRET
  # Auto mode, with the register CLI, the tests and the worktree/merge steps the skill runs approved up front.
  T1_RUNNER_NAME="runner-$(date +%H%M)" claude -p "/fix-bugs $max" \
    --permission-mode auto --max-budget-usd "$budget" --output-format text \
    --allowedTools "Bash(python3 tools/bugs/bugs.py:*)" "Bash(./test.sh:*)" "Bash(git worktree:*)" \
      "Bash(git merge --no-edit main)" "Bash(git merge --ff-only:*)" "Bash(git branch -d:*)" \
      "Bash(git commit:*)" "Bash(git add:*)" >"$log" 2>&1
  local rc=$?
  echo "$(date '+%F %T') done max=$max exit=$rc log=$log" >>"$LOGS/runner.log"
  tail -20 "$log"
}

case "$MODE" in
  --run) run "${2:-S4}"; exit 0 ;;
  --now) run S4; exit 0 ;;
esac

locked && { [ "$MODE" = --dry ] && echo "a run is in progress"; exit 0; }
status=$(python3 "$BUGS" status --json 2>>"$LOGS/runner.err") || exit 0
open_s1=$(jq -r '.open_s1 // 0' <<<"$status")
open_total=$(jq -r '.open_total // 0' <<<"$status")

hour=$(date +%H); today=$(date +%F)
window=""
if [ "$hour" -ge 18 ]; then window="$today-pm"; elif [ "$hour" -ge 8 ]; then window="$today-am"; fi
last_window=$(cat "$STATE/last-window" 2>/dev/null || true)

max=""
if [ "$open_s1" -gt 0 ]; then
  max=S1
elif [ -n "$window" ] && [ "$window" != "$last_window" ]; then
  [ "$MODE" = --dry ] || echo "$window" >"$STATE/last-window"
  [ "$open_total" -gt 0 ] && max=S4
fi

if [ "$MODE" = --dry ]; then
  echo "open S1: $open_s1, open: $open_total, window: ${window:-none} (last ${last_window:-none}) → ${max:-nothing to do}"
  exit 0
fi
[ -z "$max" ] && exit 0

if [ "$MODE" = --poll ]; then
  echo "$max" >"$STATE/next-level"
  open -g -a Terminal "$STATE/run.command"
else
  run "$max"
fi
