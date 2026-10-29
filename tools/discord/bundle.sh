#!/bin/zsh
# Lays out discord-bot for an MCP / dashboard deploy: the function's files plus the engine's standings rules copied in
# under events-engine/ (the MCP can't follow ../ imports), with standings.ts repointed and playoffs.ts's type-only
# import of pairings.ts inlined. Output: <dir> (default: a deploy/ folder beside this script, gitignored).
#   tools/discord/bundle.sh [dir]   then `deno check <dir>/index.ts`
set -euo pipefail
root=${0:A:h:h:h}
src=$root/supabase/functions/discord-bot
eng=$root/supabase/functions/events-engine
out=${1:-$root/tools/discord/deploy}
rm -rf "$out"; mkdir -p "$out/events-engine"
cp "$src"/index.ts "$src"/embeds.ts "$src"/discord.ts "$src"/telemetry.ts "$src"/verify.ts "$src"/commands.json "$out/"
sed -e 's#"../events-engine/playoffs.ts"#"./events-engine/playoffs.ts"#' -e 's#"../events-engine/types.ts"#"./events-engine/types.ts"#' "$src/standings.ts" > "$out/standings.ts"
cp "$eng/standings.ts" "$eng/types.ts" "$out/events-engine/"
sed -e 's#^import type { ProposedMatch } from "./pairings.ts";#interface ProposedMatch { tableNumber: number; side0ParticipantId: string; side1ParticipantId: string | null; isBye: boolean } // inlined from pairings.ts for the deploy#' "$eng/playoffs.ts" > "$out/events-engine/playoffs.ts"
grep -q 'from "../' "$out"/*.ts "$out"/events-engine/*.ts && { echo "a ../ import survived"; exit 1; }
echo "bundle at $out:"; (cd "$out" && find . -type f | sort)
