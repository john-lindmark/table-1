#!/usr/bin/env bash
# Pulls deck photos out of the private `deck-photos` bucket for looking at a read by hand
# (contract/deck-photo-lists-2026-11-13.md § Testing). Needs the Supabase CLI signed in and linked.
#   tools/deck-photo-lists/fetch.sh <out dir> [event id ...]     no ids = the events in testdata/deck-photo-lists/reads
# The photos are players' own: keep them out of the repository (pick a scratch folder).
set -euo pipefail
out=${1:?out dir}; shift || true
root=$(cd "$(dirname "$0")/../.." && pwd)
case "$(cd "$(dirname "$out")" 2>/dev/null && pwd)/" in "$root"/*) echo "Pick a folder outside the repository" >&2; exit 1;; esac
mkdir -p "$out"
if [ $# -eq 0 ]; then
  set -- $(python3 -c "import json,glob,sys; print(' '.join(sorted({json.load(open(f))['event_id'] for f in glob.glob(sys.argv[1]+'/testdata/deck-photo-lists/reads/*.json')})))" "$root")
fi
for e in "$@"; do
  supabase storage cp -r "ss:///deck-photos/$e" "$out/" --experimental --linked >/dev/null
  echo "$e: $(ls "$out/$e" | wc -l | tr -d ' ') photos"
done
