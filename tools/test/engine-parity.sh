#!/usr/bin/env bash
# The tournament rules exist twice: supabase/functions/events-engine (authoritative, Deno) and
# table-1-events-web/src/lib (web preview + the Vitest suite). They must stay identical apart from
# Deno's ".ts" import suffixes. Fails on any other difference.
set -euo pipefail
cd "$(dirname "$0")/../.."
ENGINE=supabase/functions/events-engine; WEB=table-1-events-web/src/lib
bad=0
for f in pairings standings seating teams roundrobin; do  # types.ts differs on purpose (web adds UI fields)
  [ -f "$ENGINE/$f.ts" ] && [ -f "$WEB/$f.ts" ] || { echo "parity: missing $f.ts in one copy"; bad=1; continue; }
  if ! diff -q <(sed -E 's/from "(\.[^"]+)\.ts"/from "\1"/' "$ENGINE/$f.ts") "$WEB/$f.ts" >/dev/null; then
    echo "parity: $f.ts differs between events-engine and web:"
    diff <(sed -E 's/from "(\.[^"]+)\.ts"/from "\1"/' "$ENGINE/$f.ts") "$WEB/$f.ts" | head -20
    bad=1
  fi
done
# The cube ranking engine: ranking-brief's copy (Deno) is the web module, byte for byte (it has no imports).
if ! diff -q supabase/functions/ranking-brief/cubeRanking.ts table-1-events-web/src/lib/cubeRanking.ts >/dev/null; then
  echo "parity: cubeRanking.ts differs between ranking-brief and web:"
  diff supabase/functions/ranking-brief/cubeRanking.ts table-1-events-web/src/lib/cubeRanking.ts | head -20
  bad=1
fi
[ $bad -eq 0 ] && echo "parity: events-engine and web rules match, and the cube ranking engine copy matches"
exit $bad
