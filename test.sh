#!/usr/bin/env bash
# Table 1 test runner. See TESTING.md.
#
#   ./test.sh            fast tier: web types + Vitest, engine/web rules parity, Deno engine tests, database tests
#   ./test.sh full       fast + iOS unit tests (own simulator) + Android unit tests
#   ./test.sh perf       performance budgets: Swiss pairing at scale, database RPC timings, web bundle size,
#                        iOS and Android scanner/catalog timings
#   ./test.sh all        full + perf
#   ./test.sh staged     what the pre-commit hook runs: only the fast-tier parts the staged files touch
#
# Every part prints PASS/FAIL; the run fails if any part fails. Needs: brew install postgresql@17 postgis deno.
set -uo pipefail
cd "$(dirname "$0")"
ROOT=$(pwd)
TIER=${1:-fast}
export LC_ALL=en_US.UTF-8
JAVA_HOME_17=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
IOS_SIM=T1-Tests                      # this runner's own simulator; never another session's
IOS_DD=/var/tmp/t1-test-dd            # its own derived data
RESULTS=(); FAILED=0

run() {  # run <name> <command...>
  local name=$1; shift
  local t0=$SECONDS log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    RESULTS+=("PASS  $name ($((SECONDS - t0))s)")
  else
    RESULTS+=("FAIL  $name ($((SECONDS - t0))s)"); FAILED=$((FAILED + 1))
    echo "---- $name failed ----"; tail -40 "$log"
  fi
  grep -hE "^ *perf |perf (swiss|ios|android|web)" "$log" | sed 's/^ */      /' | sort -u >>"$ROOT/.test-perf.log" || true
  rm -f "$log"
}

web_unit()   { (cd table-1-events-web && npx tsc -b && npx vitest run); }
parity()     { tools/test/engine-parity.sh; }
engine()     { (cd supabase/functions && deno test --quiet events-engine/); }
database()   { supabase/tests/run.sh; }
ios_unit() {
  xcrun simctl list devices | grep -q " $IOS_SIM (" || xcrun simctl create "$IOS_SIM" "iPhone 17" >/dev/null
  (cd apps/ios && xcodegen -q && xcodebuild -project "Table 1.xcodeproj" -scheme "Table 1" \
     -destination "platform=iOS Simulator,name=$IOS_SIM" -derivedDataPath "$IOS_DD" test) \
    | grep -E "perf ios|error:|Executed .* tests|TEST (SUCCEEDED|FAILED)"
  return "${PIPESTATUS[0]}"
}
android_unit() { (cd apps/android && JAVA_HOME=$JAVA_HOME_17 ./gradlew -q testDebugUnitTest -i) | grep -E "perf android|FAILED|BUILD"; return "${PIPESTATUS[0]}"; }
web_perf()   { (cd table-1-events-web && T1_PERF=1 npx vitest run src/lib/tournament.perf.test.ts src/lib/roto.perf.test.ts) && tools/test/web-bundle.sh; }
db_perf()    { T1_PERF=1 supabase/tests/run.sh perf_; }

fast() { run "web types + unit" web_unit; run "rules parity" parity; run "engine (deno)" engine; run "database" database; }
full() { fast; run "ios unit + perf" ios_unit; run "android unit + perf" android_unit; }
perf() { run "web perf + bundle" web_perf; run "database perf" db_perf; }

staged() {
  local files; files=$(git diff --cached --name-only)
  [ -z "$files" ] && { echo "nothing staged"; return; }
  grep -qE '^(table-1-events-web/|supabase/functions/events-engine/)' <<<"$files" && { run "web types + unit" web_unit; run "rules parity" parity; }
  grep -qE '^supabase/functions/events-engine/' <<<"$files" && run "engine (deno)" engine
  grep -qE '^supabase/(migrations|tests)/' <<<"$files" && run "database" database
  true
}

: >"$ROOT/.test-perf.log"
case $TIER in
  fast) fast ;; full) full ;; perf) perf ;; all) full; perf ;; staged) staged ;;
  *) echo "usage: ./test.sh [fast|full|perf|all|staged]"; exit 2 ;;
esac

echo; printf '%s\n' "${RESULTS[@]}"
[ -s "$ROOT/.test-perf.log" ] && { echo "timings:"; cat "$ROOT/.test-perf.log"; }
rm -f "$ROOT/.test-perf.log"
exit $((FAILED > 0))
