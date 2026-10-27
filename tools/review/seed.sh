#!/bin/zsh
# Signs in as the store review account (appreview@table-1.site) with the code in the Keychain and reseeds it:
# demo events reset (demo_seed), Library from the iOS demo fixture (idempotent). See APP-REVIEW.md.
set -euo pipefail
root=${0:A:h:h:h}
env=$root/table-1-events-web/.env
URL=$(grep '^VITE_SUPABASE_URL' $env | cut -d= -f2-)
KEY=$(grep '^VITE_SUPABASE_ANON_KEY' $env | cut -d= -f2-)
PW=$(security find-generic-password -s 'Table 1 App Review' -a appreview@table-1.site -w)
TOK=$(curl -sf "$URL/auth/v1/token?grant_type=password" -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"appreview@table-1.site\",\"password\":\"$PW\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
H=(-H "apikey: $KEY" -H "Authorization: Bearer $TOK" -H "Content-Type: application/json")
echo "demo events: $(curl -sf -X POST "$URL/rest/v1/rpc/demo_seed" "${H[@]}" -d '{}')"
URL=$URL KEY=$KEY TOK=$TOK python3 -I $root/tools/review/seed_library.py $root/apps/ios/Table1/DebugResources/library-demo.json
