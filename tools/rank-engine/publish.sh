#!/bin/zsh
# Publishes the cube ranking engine file the apps download (contract/cube-rankings-2026-10-21.md § The engine as a file).
# Server-facing: run only with John's OK. Builds (tools/rank-engine/build.mjs checks every shared case through the file),
# uploads the file, then the manifest last (so no phone reads a manifest whose file isn't there yet), then reads both
# back from the public URL and checks the hash.
#
#   tools/rank-engine/publish.sh
#
# Phones use the file only when its rules are newer than their own engine's (CubeRanking.rules / RULES). To pull a file
# back, publish a manifest whose rules are today's native rules: phones then keep their own engine.
set -euo pipefail
cd "$(dirname "$0")/../.."
node tools/rank-engine/build.mjs
dist=tools/rank-engine/dist-engine
file=$(python3 -c 'import json; print(json.load(open("'$dist'/manifest.json"))["file"])')
sha=$(python3 -c 'import json; print(json.load(open("'$dist'/manifest.json"))["sha256"])')
supabase storage cp --experimental --linked --content-type application/javascript --cache-control "public, max-age=31536000, immutable" \
  "$dist/$file" "ss:///catalog/engines/rank/$file"
supabase storage cp --experimental --linked --content-type application/json --cache-control "no-cache, max-age=0" \
  "$dist/manifest.json" "ss:///catalog/engines/rank/manifest.json"
base="$(supabase status --linked -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("API_URL",""))' || true)"
[ -n "$base" ] || base="https://aaozhfcbvqrgkkrihkrd.supabase.co"
got=$(curl -fsS "$base/storage/v1/object/public/catalog/engines/rank/$file" | shasum -a 256 | cut -d' ' -f1)
[ "$got" = "$sha" ] || { echo "publish: the public file's hash is $got, the manifest says $sha"; exit 1; }
curl -fsS -H 'Cache-Control: no-cache' "$base/storage/v1/object/public/catalog/engines/rank/manifest.json" | grep -q "$sha" \
  || { echo "publish: the public manifest doesn't name $file"; exit 1; }
echo "publish: $file live (sha $sha)"
