#!/bin/zsh
# Lays out discord-bot for an MCP / dashboard deploy: the function's files plus the engine's standings rules copied in
# under events-engine/ and the rankings engine under ranking-brief/ (the MCP can't follow ../ imports), with
# standings.ts, embeds.ts (seating.ts's pod plan) and ranking.ts repointed and playoffs.ts's and teams.ts's type-only import of pairings.ts inlined.
# Output: <dir> (default: a deploy/ folder beside this script, gitignored).
#   tools/discord/bundle.sh [dir]   then `deno check <dir>/index.ts`
set -euo pipefail
root=${0:A:h:h:h}
src=$root/supabase/functions/discord-bot
eng=$root/supabase/functions/events-engine
out=${1:-$root/tools/discord/deploy}
rm -rf "$out"; mkdir -p "$out/events-engine" "$out/ranking-brief"
cp "$src"/index.ts "$src"/discord.ts "$src"/photos.ts "$src"/telemetry.ts "$src"/verify.ts "$src"/commands.json "$out/"
sed -e 's#"../events-engine/#"./events-engine/#' "$src/standings.ts" > "$out/standings.ts"
sed -e 's#"../events-engine/#"./events-engine/#' "$src/embeds.ts" > "$out/embeds.ts"
sed -e 's#"../ranking-brief/#"./ranking-brief/#' "$src/ranking.ts" > "$out/ranking.ts"
cp "$root/supabase/functions/ranking-brief/cubeRanking.ts" "$root/supabase/functions/ranking-brief/brief.ts" "$out/ranking-brief/"
cp "$eng/standings.ts" "$eng/types.ts" "$eng/seating.ts" "$out/events-engine/"
for f in playoffs teams; do
  sed -e 's#^import type { ProposedMatch } from "./pairings.ts";#interface ProposedMatch { tableNumber: number; side0ParticipantId: string; side1ParticipantId: string | null; isBye: boolean } // inlined from pairings.ts for the deploy#' "$eng/$f.ts" > "$out/events-engine/$f.ts"
done
grep -q 'from "../' "$out"/*.ts "$out"/events-engine/*.ts "$out"/ranking-brief/*.ts && { echo "a ../ import survived"; exit 1; }
echo "bundle at $out:"; (cd "$out" && find . -type f | sort)
