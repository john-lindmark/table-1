#!/usr/bin/env bash
# Web bundle size budget (gzipped). Measured 2026-10-16: all JS 327 KB, app entry chunk 56 KB.
# Raise a budget on purpose (and say why in the commit), never to make a red run green.
set -euo pipefail
cd "$(dirname "$0")/../../table-1-events-web"
TOTAL_JS_KB=380   # every JS chunk, gzipped
ENTRY_KB=70       # index-*.js, the app's own entry chunk
OUT=/var/tmp/t1-web-dist
npx vite build --outDir "$OUT" --emptyOutDir --logLevel error
gz() { gzip -c "$1" | wc -c; }
total=0; for f in "$OUT"/assets/*.js; do total=$((total + $(gz "$f"))); done
entry=$(gz "$(ls "$OUT"/assets/index-*.js | head -1)")
total_kb=$((total / 1024)); entry_kb=$((entry / 1024))
echo "perf web bundle: all JS ${total_kb} KB gz (budget ${TOTAL_JS_KB}), entry ${entry_kb} KB gz (budget ${ENTRY_KB})"
[ "$total_kb" -le "$TOTAL_JS_KB" ] && [ "$entry_kb" -le "$ENTRY_KB" ] || { echo "FAIL web bundle over budget"; exit 1; }
