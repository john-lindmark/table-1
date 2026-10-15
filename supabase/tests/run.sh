#!/usr/bin/env bash
# Usage: test/run.sh  — rebuilds a scratch DB, applies baseline + V1 migration, runs the checks.
set -euo pipefail
cd "$(dirname "$0")/.."
H=${PGHOST:-/var/tmp/t1pg}; PORT=${PGPORT:-54329}
P="psql -h $H -p $PORT -U postgres -v ON_ERROR_STOP=1 -q -t"
$P -d postgres -c "drop database if exists t1" -c "create database t1"
$P -d t1 -f tests/00_local_baseline.sql
$P -d t1 -f supabase/migrations/20261006120000_events_v1_accounts_records.sql
$P -d t1 -f tests/10_events_v1_test.sql 2>&1 | grep -E "NOTICE|ERROR|FAIL|PASSED" | sed 's/^.*NOTICE:  //'
