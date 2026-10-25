#!/usr/bin/env bash
# The Insights demo packs (testdata/insights, copied to the iOS and Android Debug resources): real MTGO results and
# 17Lands data run through the same SQL and pack code the server uses.
#   tools/insights/demo_packs.sh <scratch dir> <through yyyy-mm-dd> [briefs.json]
# The demo briefs (tools/insights/demo-briefs.json) were written to the facts sheets this prints and pass the same
# checks as the server's (insight-brief/brief.ts problems()).
# <scratch dir> holds: mtgo/pages/<slug>.json (each event page's data), topdeck/<Format>.json (TopDeck.gg answers,
# optional), scryfall/default.jsonl.gz and scryfall/sets.json (Scryfall bulk data), and 17l/*.sql
# (tools/insights/limited_local.ts output for the Limited set).
set -euo pipefail
cd "$(dirname "$0")/../.."
S=$1; THROUGH=$2; BRIEFS=${3:-}
python3 -I tools/insights/load_catalog.py "$S/scryfall/default.jsonl.gz" "$S/scryfall/sets.json" "$S/catalog"
deno run --allow-read --allow-write tools/insights/pages_to_events.ts "$S/mtgo/pages" "$S/events.jsonl"
if [ -d "$S/topdeck" ]; then
  deno run --allow-read --allow-write tools/insights/topdeck_to_events.ts "$S/topdeck" "$S/topdeck-events.jsonl"
  cat "$S/topdeck-events.jsonl" >> "$S/events.jsonl"
fi
tools/insights/demo_db.sh "$S/catalog" "$S/events.jsonl"
P="${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}/psql -h ${PGHOST:-/var/tmp/t1pg} -p ${PGPORT:-54329} -U postgres -X -q -v ON_ERROR_STOP=1 -d t1_insights_demo"
for f in "$S"/17l/*-game.sql "$S"/17l/*-draft.sql; do [ -e "$f" ] && $P -f "$f"; done
deno run --allow-run --allow-read --allow-write tools/insights/demo_packs.ts "$THROUGH" "$BRIEFS" "$S/facts.json"
for f in testdata/insights/constructed-*.json testdata/insights/limited-*.json; do
  cp "$f" "apps/ios/Table1/DebugResources/insights-demo-$(basename "$f")"
done
cp testdata/insights/pages.json apps/ios/Table1/DebugResources/insights-demo-pages.json
echo "facts sheets: $S/facts.json"
