#!/usr/bin/env bash
# A local database with every migration, a real card catalog and real MTGO events, for running the Insights SQL on
# real data and building the demo packs (demo_packs.ts). Uses the test cluster of supabase/tests/run.sh.
#   tools/insights/demo_db.sh <catalog dir from load_catalog.py> <events.jsonl from pages_to_events.ts>
set -euo pipefail
cd "$(dirname "$0")/../.."
CAT=$1; EVENTS=$2
BIN=${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}
P="$BIN/psql -h ${PGHOST:-/var/tmp/t1pg} -p ${PGPORT:-54329} -U postgres -v ON_ERROR_STOP=1 -q -X"
supabase/tests/run.sh 96_library >/dev/null   # builds t1_template when migrations changed
$P -d postgres -c "drop database if exists t1_insights_demo" -c "create database t1_insights_demo template t1_template"
D="$P -d t1_insights_demo"
$D <<SQL
alter table public.card_oracles disable trigger user;
\copy public.mtg_sets (code, name, set_type, released_at, icon_svg_uri, card_count, digital) from '$CAT/sets.tsv'
\copy public.card_oracles (oracle_id, name, name_norm, face_names, layout, type_line, mana_cost, cmc, colors, color_identity, legalities, source_card_id, source_rank, content_hash) from '$CAT/oracles.tsv'
update public.card_oracles set name_norm = public.card_name_norm(name);
insert into public.card_names (name_norm, oracle_id, is_face)
select distinct on (v.nm, o.oracle_id) v.nm, o.oracle_id, v.f from public.card_oracles o,
  lateral (select o.name_norm nm, false f union all select public.card_name_norm(x), true from unnest(o.face_names) x) v
 where v.nm <> '' order by v.nm, o.oracle_id, v.f on conflict do nothing;
\copy public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, printed_name, released_at, image_ts, image_faces, content_hash) from '$CAT/cards.tsv'
alter table public.card_oracles enable trigger user;
select t1_private.meta_rule_compile(id) from t1_private.meta_archetypes;
create temporary table ev (j jsonb);
\copy ev from program 'sed -e "s/\\\\\\\\/\\\\\\\\\\\\\\\\/g" $EVENTS'
select count(*) events, sum((public.meta_ingest(j)->>'decks')::int) decks from ev;
select t1_private.meta_legality_propose();
SQL
$D -c "select format, count(*) decks, round(100.0 * count(*) filter (where archetype_id = 0) / count(*), 1) other_pct from t1_private.meta_decks group by 1 order by 1"
$D -c "select format, name, array_to_string(missing, '; ') missing from t1_private.meta_archetypes where cardinality(missing) > 0"
