#!/usr/bin/env bash
# Database tests against every migration, on a local Homebrew Postgres 17 + PostGIS.
#
#   supabase/tests/run.sh              all *_test.sql files
#   supabase/tests/run.sh 20_rules     files whose name contains "20_rules"
#   T1_PERF=1 supabase/tests/run.sh    also the perf_*.sql files (seeded timings, see perf_budgets.tsv)
#
# One template DB (baseline stubs + all migrations) is rebuilt only when a migration or the baseline
# changes; each test file then runs in its own fresh copy, so files never see each other's rows.
# Setup: brew install postgresql@17 postgis. The cluster lives in /var/tmp/t1pg and is started on demand.
set -euo pipefail
cd "$(dirname "$0")"
export LC_ALL=en_US.UTF-8
BIN=${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}
H=${PGHOST:-/var/tmp/t1pg}; PORT=${PGPORT:-54329}
P="$BIN/psql -h $H -p $PORT -U postgres -v ON_ERROR_STOP=1 -q -X"
A="env PGOPTIONS=-cclient_min_messages=warning $P -d postgres"   # admin: create/drop quietly

if ! $BIN/pg_isready -q -h "$H" -p "$PORT"; then
  mkdir -p "$H"
  [ -d "$H/data" ] || $BIN/initdb -D "$H/data" -U postgres -A trust --no-locale -E UTF8 >/dev/null
  $BIN/pg_ctl -D "$H/data" -l "$H/log" -o "-p $PORT -k $H -c listen_addresses='' -c fsync=off" -w start >/dev/null
fi

# Template ------------------------------------------------------------------
# Several Claude sessions share this cluster: one rebuild at a time, and each run's DBs carry its pid.
LOCK="$H/template.lock"
until mkdir "$LOCK" 2>/dev/null; do
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null; sleep 0.5
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
HASH=$(cat 00_local_baseline.sql ../migrations/*.sql | shasum | cut -c1-12)
HAVE=$($P -d postgres -tAc "select shobj_description(oid, 'pg_database') from pg_database where datname = 't1_template'" || true)
if [ "$HAVE" != "$HASH" ]; then
  echo "building template (migrations changed)"
  $A -c "drop database if exists t1_template" -c "create database t1_template"
  $P -d t1_template -f 00_local_baseline.sql >/dev/null
  for m in ../migrations/*.sql; do
    # pg_cron, pgmq and pg_net are Supabase-only; the baseline stubs them.
    if ! sed -E '/create extension if not exists (pg_cron|pgmq|pg_net)/d' "$m" | $P -d t1_template -f - >/dev/null 2>"$H/migration.err"; then
      echo "MIGRATION FAILED: $(basename "$m")"; cat "$H/migration.err"; exit 1
    fi
  done
  $A -c "comment on database t1_template is '$HASH'"
fi
rmdir "$LOCK"; trap - EXIT

# Tests ---------------------------------------------------------------------
FILTER=${1:-}
FILES=$(ls [0-9]*_test.sql)
[ "${T1_PERF:-}" = 1 ] && FILES="$FILES $(ls perf_*.sql 2>/dev/null || true)"
FAILED=0; RAN=0
for f in $FILES; do
  [[ -n "$FILTER" && "$f" != *"$FILTER"* ]] && continue
  db="t1_$(basename "$f" .sql)_$$"
  $A -c "drop database if exists $db" -c "create database $db template t1_template"
  RAN=$((RAN + 1))
  if out=$($P -d "$db" -f "$f" 2>&1); then
    n=$(grep -c "NOTICE:  ok" <<<"$out" || true)
    echo "PASS $f ($n checks)"
    grep -E "NOTICE:  perf" <<<"$out" | sed 's/^.*NOTICE:  /     /' || true
  else
    FAILED=$((FAILED + 1))
    echo "FAIL $f"
    grep -E "ERROR|FAIL|CONTEXT|LINE" <<<"$out" | sed 's/^/     /' | head -20
  fi
  $A -c "drop database if exists $db"
done
[ "$RAN" -gt 0 ] || { echo "no test files matched '$FILTER'"; exit 1; }
[ "$FAILED" -eq 0 ] || { echo "$FAILED of $RAN database test files failed"; exit 1; }
echo "database: $RAN files passed"
