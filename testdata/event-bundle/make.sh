#!/usr/bin/env bash
# Regenerates the event read fixtures from the real RPCs (contract/privacy-lockdown-2026-10-18.md): a copy of the test
# template database (every migration), one seeded event, then event_bundle / event_public / event_preview as JSON.
# Clients decode these in their tests (iOS EventBundleTests, web eventBundle.test.ts, Android EventBundleTest), so a
# shape change on the server fails the client tests. Run supabase/tests/run.sh once first (it builds the template).
#   testdata/event-bundle/make.sh
set -euo pipefail
cd "$(dirname "$0")"
BIN=${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}
P="$BIN/psql -h ${PGHOST:-/var/tmp/t1pg} -p ${PGPORT:-54329} -U postgres -v ON_ERROR_STOP=1 -q -X"
DB=t1_fixture_$$
$P -d postgres -c "create database $DB template t1_template" >/dev/null
trap '$P -d postgres -c "drop database if exists $DB" >/dev/null' EXIT
$P -d "$DB" >/dev/null <<'SQL'
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'org@example.com', '{"full_name": "Ana Organizer"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Player"}');
insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds, format_name, set_name, venue_name)
values ('e0000000-0000-0000-0000-000000000001', 'FIXT', 'Fixture draft', '00000000-0000-0000-0000-0000000000a1',
        'in_progress', 2, 3, 'draft', 'Murders at Karlov Manor', 'Denver Card Shop');
insert into public.event_members (event_id, user_id, role) values ('e0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'owner');
insert into public.pods (id, event_id) values ('d0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001');
insert into public.participants (id, event_id, pod_id, user_id, display_name, seat) values
  ('f0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'Ana Organizer', 1),
  ('f0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b1', 'Ben Player', 2),
  ('f0000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', null, 'Guest Cara', 3);
insert into public.rounds (id, event_id, number, status) values
  ('a0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 1, 'recorded'),
  ('a0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 2, 'active');
insert into public.matches (id, event_id, round_id, table_number, status, game_draws) values
  ('b0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 1, 'confirmed', 1),
  ('b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 1, 'pending', 0);
insert into public.matches (id, event_id, round_id, is_bye, status) values
  ('b0000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', true, 'confirmed');
insert into public.match_sides (match_id, participant_id, side, game_wins) values
  ('b0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', 0, 2),
  ('b0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000003', 1, 1),
  ('b0000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000001', 0, 0),
  ('b0000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000002', 1, 0),
  ('b0000000-0000-0000-0000-000000000003', 'f0000000-0000-0000-0000-000000000003', 0, 2);
SQL
dump() {  # $1 file, $2 role, $3 user, $4 sql
  $P -d "$DB" -tA -c "set role $2; select set_config('request.jwt.claim.sub', '$3', false), set_config('request.jwt.claim.role', '$2', false);" \
     -c "$4" | tail -1 | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), indent=2, sort_keys=True))' > "$1"
}
dump bundle.json authenticated 00000000-0000-0000-0000-0000000000a1 "select public.event_bundle('e0000000-0000-0000-0000-000000000001')"
dump public.json anon "" "select public.event_public('e0000000-0000-0000-0000-000000000001')"
dump preview.json anon "" "select public.event_preview('FIXT')"
echo "wrote bundle.json public.json preview.json"
