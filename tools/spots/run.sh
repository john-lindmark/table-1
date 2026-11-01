#!/usr/bin/env bash
# Re-shoots the feature spots and rewrites the store copy (marketing/). Run after a UI change to any screen a spot
# shows, or after editing marketing/bundle/spots/spots.json; then commit marketing/. First run installs Playwright
# and its Chromium (~150 MB) under tools/spots/node_modules.
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules/playwright ] || npm install --no-audit --no-fund
npx playwright install chromium
node shoot.mjs "$@"
node copy.mjs
