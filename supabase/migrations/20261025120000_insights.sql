-- Insights (contract/insights-2026-10-24.md, plan table-1-context/docs/plan-insights-2026-10-24.md).
-- Constructed: MTGO decklist pages (and TopDeck.gg once its key is set) → events, decks with their cards as Oracle
-- ids, top-8 matches; decks labelled by archetype rules; packs of facts per format built from them.
-- Limited: 17Lands public game and draft data, read in resumable slices into per-run sums; one pack per set.
-- Packs are published by the meta-sync / limited-sync edge functions to the public catalog bucket (insights/...).
--  - Everything lives in t1_private; clients read packs, insights_index and three read RPCs.
--  - No player names are stored: a salted hash is kept only to tie a deck to its bracket matches.
--  - Worker RPCs are service_role only. Review RPCs are moderators only and audited.

-- ==================================================================== a_settings
create table if not exists t1_private.meta_formats (
  format text primary key,
  name text not null,
  ord integer not null,
  enabled boolean not null default false,
  topdeck text not null                        -- TopDeck.gg's format name (case sensitive)
);
insert into t1_private.meta_formats (format, name, ord, enabled, topdeck) values
  ('standard', 'Standard', 1, true, 'Standard'), ('pioneer', 'Pioneer', 2, true, 'Pioneer'),
  ('modern', 'Modern', 3, true, 'Modern'), ('pauper', 'Pauper', 4, true, 'Pauper'),
  ('legacy', 'Legacy', 5, false, 'Legacy'), ('vintage', 'Vintage', 6, false, 'Vintage'),
  ('premodern', 'Premodern', 7, false, 'Premodern')
on conflict (format) do nothing;

create table if not exists t1_private.meta_tiers (
  tier text primary key,
  weight numeric not null,
  ord integer not null
);
insert into t1_private.meta_tiers (tier, weight, ord) values
  ('major', 4, 1), ('large', 2, 2), ('regular', 1, 3), ('small', 0.5, 4)
on conflict (tier) do nothing;

-- One row: tuning and the workers' state (backfill cursor, last index read, leases).
create table if not exists t1_private.meta_settings (
  id boolean primary key default true check (id),
  top8_factor numeric not null default 2,
  thin_below numeric not null default 40,
  salt text not null default encode(extensions.gen_random_bytes(16), 'hex'),
  state jsonb not null default '{}'::jsonb
);
insert into t1_private.meta_settings (id) values (true) on conflict do nothing;

-- ==================================================================== b_constructed_tables
create table if not exists t1_private.meta_queue (
  id bigserial primary key,
  source text not null check (source in ('mtgo', 'topdeck')),
  format text not null references t1_private.meta_formats(format),
  slug text not null,
  url text not null,
  status text not null default 'pending' check (status in ('pending', 'running', 'done', 'failed', 'skipped')),
  attempts integer not null default 0,
  error text,
  queued_at timestamptz not null default now(),
  started_at timestamptz,
  done_at timestamptz,
  unique (source, slug)
);
create index if not exists meta_queue_pending_idx on t1_private.meta_queue (queued_at) where status in ('pending', 'running');

create table if not exists t1_private.meta_events (
  id bigserial primary key,
  source text not null check (source in ('mtgo', 'topdeck')),
  source_id text not null,
  format text not null references t1_private.meta_formats(format),
  name text not null,
  kind text not null check (kind in ('challenge', 'league', 'showcase', 'qualifier', 'championship', 'paper', 'other')),
  on_date date not null,
  players integer,
  tier text not null references t1_private.meta_tiers(tier),
  url text,
  complete boolean not null default false,       -- every deck of the field is known (conversion rates)
  ingested_at timestamptz not null default now(),
  unique (source, source_id)
);
create index if not exists meta_events_format_idx on t1_private.meta_events (format, on_date);

create table if not exists t1_private.meta_decks (
  id bigserial primary key,
  event_id bigint not null references t1_private.meta_events(id) on delete cascade,
  format text not null,
  on_date date not null,
  tier text not null,
  weight numeric not null,
  player text not null,                          -- salted hash, never a name
  rank integer,
  wins integer,
  losses integer,
  draws integer,
  top8 boolean not null default false,
  main uuid[] not null,
  main_qty smallint[] not null,
  side uuid[] not null,
  side_qty smallint[] not null,
  colors text not null default '',
  archetype_id integer not null default 0
);
create index if not exists meta_decks_window_idx on t1_private.meta_decks (format, on_date);
create index if not exists meta_decks_event_idx on t1_private.meta_decks (event_id);
create index if not exists meta_decks_archetype_idx on t1_private.meta_decks (format, archetype_id, on_date);
create index if not exists meta_decks_main_idx on t1_private.meta_decks using gin (main);
create index if not exists meta_decks_side_idx on t1_private.meta_decks using gin (side);

create table if not exists t1_private.meta_matches (
  event_id bigint not null references t1_private.meta_events(id) on delete cascade,
  round text not null,
  a bigint not null references t1_private.meta_decks(id) on delete cascade,
  b bigint not null references t1_private.meta_decks(id) on delete cascade,
  a_wins integer,
  b_wins integer,
  result text not null check (result in ('a', 'b', 'draw')),
  primary key (event_id, round, a, b)
);

create table if not exists t1_private.meta_unmatched (
  source text not null,
  name text not null,
  seen integer not null default 1,
  last_seen date not null default current_date,
  primary key (source, name)
);

create table if not exists t1_private.meta_archetypes (
  id serial primary key,
  format text not null references t1_private.meta_formats(format),
  name text not null,
  family text not null check (family in ('aggro', 'midrange', 'control', 'combo', 'ramp')),
  colors text not null default '',
  status text not null default 'proposed' check (status in ('approved', 'proposed', 'rejected', 'retired')),
  rule jsonb not null,                           -- names: {main, any, deck, not}
  priority integer not null default 100,
  source text not null default 'seed' check (source in ('seed', 'claude', 'john')),
  signature text[] not null default '{}',        -- cards that defined the cluster (proposals)
  sample_decks integer,
  -- compiled from rule (meta_rule_compile): Oracle ids; a name the catalog doesn't know goes in missing
  r_main uuid[] not null default '{}',
  r_deck uuid[] not null default '{}',
  r_not uuid[] not null default '{}',
  r_any1 uuid[],
  r_any2 uuid[],
  r_any3 uuid[],
  missing text[] not null default '{}',
  blocked boolean not null default false,        -- a main or deck card is missing: the rule can't be right without it
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (format, name)
);

create table if not exists t1_private.meta_format_changes (
  id serial primary key,
  format text not null references t1_private.meta_formats(format),
  on_date date not null,
  kind text not null check (kind in ('ban', 'unban', 'restrict', 'unrestrict', 'set_release', 'rotation')),
  cards text[] not null default '{}',
  set_code text,
  note text,
  url text,
  status text not null default 'proposed' check (status in ('confirmed', 'proposed', 'rejected')),
  created_at timestamptz not null default now(),
  unique nulls not distinct (format, on_date, kind, set_code)
);

-- Daily legality diff of the catalog (trigger on card_oracles), grouped into proposed changes by meta_legality_propose.
create table if not exists t1_private.meta_legality_log (
  oracle_id uuid not null,
  format text not null,
  before text,
  after text,
  seen date not null default current_date,
  proposed boolean not null default false,
  primary key (oracle_id, format, seen)
);

create table if not exists t1_private.insight_packs (
  kind text not null check (kind in ('constructed', 'limited')),
  key text not null,
  name text not null,
  ord integer not null default 0,
  version text not null,
  path text not null,
  bytes integer not null,
  sha256 text not null,
  through date,
  built_at timestamptz not null default now(),
  primary key (kind, key)
);

-- Latest brief per view; reused while its facts hash is unchanged, kept when a rewrite fails.
create table if not exists t1_private.insight_briefs (
  view text primary key,
  facts_hash text not null,
  brief text not null,
  model text,
  created_at timestamptz not null default now()
);

create table if not exists t1_private.insights_audit (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor uuid,
  action text not null,
  target text not null,
  detail jsonb not null default '{}'::jsonb
);

-- ==================================================================== c_limited_tables
create table if not exists t1_private.limited_runs (
  id bigserial primary key,
  set_code text not null,                        -- 17Lands' code, upper case (FRA)
  event_type text not null check (event_type in ('PremierDraft', 'TradDraft', 'PickTwoDraft', 'Sealed', 'TradSealed')),
  kind text not null check (kind in ('game', 'draft')),
  uri text not null,
  last_modified timestamptz not null,
  total_bytes bigint not null,
  status text not null default 'pending' check (status in ('pending', 'running', 'done', 'failed', 'superseded')),
  step integer not null default 0,
  bit bigint,
  win text,                                      -- base64 of the inflate window
  carry text,                                    -- base64 of the partial line
  header jsonb,                                  -- column layout, from the first slice
  rows bigint not null default 0,
  in_flight_at timestamptz,
  attempts integer not null default 0,
  error text,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  unique (set_code, event_type, kind, last_modified)
);

-- Sums per run: k names what is counted (see limited-sync/parse.ts), g = games (or picks), w = wins (or pick sum).
create table if not exists t1_private.limited_acc (
  run_id bigint not null references t1_private.limited_runs(id) on delete cascade,
  k text not null,
  g bigint not null default 0,
  w bigint not null default 0,
  primary key (run_id, k)
);

-- ==================================================================== d_helpers
create or replace function t1_private.meta_tier(p_kind text, p_players integer)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_kind in ('showcase', 'qualifier', 'championship') or coalesce(p_players, 0) >= 128 then 'major'
    when p_kind = 'league' then 'small'
    when coalesce(p_players, 0) >= 64 then 'large'
    when coalesce(p_players, 0) >= 32 then 'regular'
    else 'small' end;
$$;

create or replace function t1_private.meta_tier_in(p_tier text, p_scope text)
returns boolean language sql immutable set search_path = '' as $$
  select p_scope = 'all' or p_tier in ('major', 'large');
$$;

-- Oracle id for a card name as a source prints it ("Fire // Ice", a front face, accents). Null when unknown.
create or replace function t1_private.meta_card_id(p_name text)
returns uuid language sql stable set search_path = '' as $$
  select n.oracle_id from public.card_names n
   where n.name_norm = public.card_name_norm(split_part(p_name, ' // ', 1)) or n.name_norm = public.card_name_norm(p_name)
   order by (n.name_norm = public.card_name_norm(p_name)) desc, n.is_face, n.oracle_id
   limit 1;
$$;

create or replace function t1_private.meta_is_basic(p_oracle uuid)
returns boolean language sql stable set search_path = '' as $$
  select coalesce((select o.type_line ~ '^Basic' from public.card_oracles o where o.oracle_id = p_oracle), false);
$$;

-- Colours of a main deck: a colour counts when its nonland cards add up to 4 copies or more. WUBRG order.
create or replace function t1_private.meta_colors(p_ids uuid[], p_qty smallint[])
returns text language sql stable set search_path = '' as $$
  with c as (
    select col, sum(q) n
      from unnest(p_ids, p_qty) u(id, q)
      join public.card_oracles o on o.oracle_id = u.id
      cross join lateral unnest(o.colors) col
     where coalesce(o.type_line, '') !~ 'Land'
     group by col)
  select coalesce(string_agg(col, '' order by position(col in 'WUBRG')), '') from c where n >= 4;
$$;

create or replace function t1_private.meta_ids(p jsonb)
returns uuid[] language sql stable set search_path = '' as $$
  select coalesce(array_agg(distinct t1_private.meta_card_id(x)) filter (where t1_private.meta_card_id(x) is not null), '{}')
    from jsonb_array_elements_text(coalesce(p, '[]'::jsonb)) x;
$$;

-- Compiles an archetype's rule names into Oracle ids and lists the names the catalog doesn't know. A missing name in
-- an "any" group or in "not" is just left out; a missing main or deck card blocks the rule.
create or replace function t1_private.meta_rule_compile(p_id integer)
returns void language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_missing text[]; v_blocked boolean;
begin
  select rule into r from t1_private.meta_archetypes where id = p_id;
  if r is null then return; end if;
  select coalesce(array_agg(distinct x), '{}') into v_missing
    from (select jsonb_array_elements_text(coalesce(r->'main', '[]')) x
          union all select jsonb_array_elements_text(coalesce(r->'deck', '[]'))
          union all select jsonb_array_elements_text(coalesce(r->'not', '[]'))
          union all select jsonb_array_elements_text(g) from jsonb_array_elements(coalesce(r->'any', '[]')) g) n
   where t1_private.meta_card_id(x) is null;
  select exists (select 1 from (select jsonb_array_elements_text(coalesce(r->'main', '[]')) x
                                union all select jsonb_array_elements_text(coalesce(r->'deck', '[]'))) n
                  where t1_private.meta_card_id(x) is null) into v_blocked;
  update t1_private.meta_archetypes set
    r_main = t1_private.meta_ids(r->'main'),
    r_deck = t1_private.meta_ids(r->'deck'),
    r_not = t1_private.meta_ids(r->'not'),
    r_any1 = case when jsonb_array_length(coalesce(r->'any', '[]')) >= 1 then t1_private.meta_ids(r->'any'->0) end,
    r_any2 = case when jsonb_array_length(coalesce(r->'any', '[]')) >= 2 then t1_private.meta_ids(r->'any'->1) end,
    r_any3 = case when jsonb_array_length(coalesce(r->'any', '[]')) >= 3 then t1_private.meta_ids(r->'any'->2) end,
    missing = v_missing, blocked = v_blocked, updated_at = now()
   where id = p_id;
end $$;

create or replace function t1_private.meta_archetype_compiled()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.meta_rule_compile(new.id);
  return null;
end $$;
drop trigger if exists meta_archetypes_compile on t1_private.meta_archetypes;
create trigger meta_archetypes_compile after insert or update of rule on t1_private.meta_archetypes
  for each row execute function t1_private.meta_archetype_compiled();

-- The first approved archetype (by priority) whose rule a deck meets; 0 = Other. A blocked rule never matches.
create or replace function t1_private.meta_label(p_format text, p_main uuid[], p_side uuid[])
returns integer language sql stable set search_path = '' as $$
  select coalesce((
    select a.id from t1_private.meta_archetypes a
     where a.format = p_format and a.status = 'approved' and not a.blocked
       and (cardinality(a.r_main) + cardinality(a.r_deck) + coalesce(cardinality(a.r_any1), 0)) > 0
       and a.r_main <@ p_main
       and a.r_deck <@ (p_main || p_side)
       and (a.r_any1 is null or a.r_any1 && (p_main || p_side))
       and (a.r_any2 is null or a.r_any2 && (p_main || p_side))
       and (a.r_any3 is null or a.r_any3 && (p_main || p_side))
       and not (a.r_not && (p_main || p_side))
     order by a.priority, a.id limit 1), 0);
$$;

-- Relabels a format's decks under the current rules (after an approval), or with p_other_only only the decks no
-- rule named yet (each pack build: a rule whose card the catalog has just learned starts matching).
create or replace function public.meta_relabel(p_format text, p_other_only boolean default false)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform t1_private.meta_rule_compile(id) from t1_private.meta_archetypes where format = p_format and status = 'approved';
  update t1_private.meta_decks d set archetype_id = l.a
    from (select id, t1_private.meta_label(format, main, side) a from t1_private.meta_decks
           where format = p_format and (not p_other_only or archetype_id = 0)) l
   where d.id = l.id and d.archetype_id is distinct from l.a;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function t1_private.insights_post(p_fn text, p_body jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/' || p_fn,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 150000);
end $$;

-- ==================================================================== e_ingest
create or replace function public.meta_state()
returns jsonb language sql stable security definer set search_path = '' as $$
  select state from t1_private.meta_settings;
$$;

create or replace function public.meta_state_put(p_patch jsonb)
returns jsonb language sql security definer set search_path = '' as $$
  update t1_private.meta_settings set state = state || coalesce(p_patch, '{}'::jsonb) returning state;
$$;

-- Queues pages to read; a slug already queued is left alone. Returns how many were new.
create or replace function public.meta_queue_add(p_items jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into t1_private.meta_queue (source, format, slug, url)
  select i->>'source', i->>'format', i->>'slug', i->>'url'
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
    join t1_private.meta_formats f on f.format = i->>'format' and f.enabled
  on conflict (source, slug) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Claims up to p_n queued pages (oldest event first by slug date, so a backfill fills in order). Pages that went
-- quiet for 10 minutes go back; after 3 attempts a page is failed.
create or replace function public.meta_queue_claim(p_n integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  update t1_private.meta_queue set status = case when attempts >= 3 then 'failed' else 'pending' end,
         error = coalesce(error, 'no answer from worker')
   where status = 'running' and started_at < now() - interval '10 minutes';
  with c as (
    select id from t1_private.meta_queue where status = 'pending' and attempts < 3
     order by queued_at, id limit greatest(p_n, 0) for update skip locked),
  u as (
    update t1_private.meta_queue q set status = 'running', attempts = attempts + 1, started_at = now()
      from c where q.id = c.id
    returning q.id, q.source, q.format, q.slug, q.url)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'source', source, 'format', format, 'slug', slug, 'url', url) order by id), '[]')
    into v from u;
  return v;
end $$;

create or replace function public.meta_queue_done(p_id bigint, p_status text, p_error text default null)
returns void language sql security definer set search_path = '' as $$
  update t1_private.meta_queue
     set status = case when p_status = 'failed' and attempts < 3 then 'pending' else p_status end,
         error = left(p_error, 500), done_at = case when p_status in ('done', 'skipped') then now() end
   where id = p_id;
$$;

-- Stores one event with its decks and matches, replacing what an earlier read stored (idempotent).
--   p_event: { source, source_id, format, name, kind, on, players, url, complete,
--              decks: [{ player, rank, wins, losses, draws, top8, main: [[name, qty]], side: [[name, qty]] }],
--              matches: [{ round, a, b, a_wins, b_wins, result }] }   (a / b are players as in decks)
-- Card names the catalog doesn't know are counted in meta_unmatched and left out of the deck.
create or replace function public.meta_ingest(p_event jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_set t1_private.meta_settings;
  v_event bigint;
  v_tier text;
  v_format text := p_event->>'format';
  v_kind text := coalesce(p_event->>'kind', 'other');
  v_players integer := nullif(p_event->>'players', '')::integer;
  v_decks integer;
  v_unmatched integer;
begin
  if not exists (select 1 from t1_private.meta_formats where format = v_format) then
    raise exception 'Unknown format %', v_format using errcode = '22023';
  end if;
  if coalesce(p_event->>'source', '') not in ('mtgo', 'topdeck') or coalesce(p_event->>'source_id', '') = ''
     or (p_event->>'on') is null then
    raise exception 'An event needs a source, an id and a date' using errcode = '22023';
  end if;
  select * into v_set from t1_private.meta_settings;
  v_tier := t1_private.meta_tier(v_kind, v_players);

  insert into t1_private.meta_events as e (source, source_id, format, name, kind, on_date, players, tier, url, complete)
  values (p_event->>'source', p_event->>'source_id', v_format, coalesce(p_event->>'name', ''), v_kind,
          (p_event->>'on')::date, v_players, v_tier, p_event->>'url', coalesce((p_event->>'complete')::boolean, false))
  on conflict (source, source_id) do update
    set name = excluded.name, kind = excluded.kind, on_date = excluded.on_date, players = excluded.players,
        tier = excluded.tier, url = excluded.url, complete = excluded.complete, ingested_at = now()
  returning id into v_event;
  delete from t1_private.meta_decks where event_id = v_event;

  -- Every card line, resolved once.
  if to_regclass('pg_temp.meta_lines') is null then
    create temporary table meta_lines (n integer, player text, side boolean, name text, qty integer, id uuid) on commit drop;
  else
    truncate meta_lines;
  end if;
  insert into meta_lines
  select d.n, d.v->>'player', s.side, l->>0, (l->>1)::integer, null
    from jsonb_array_elements(coalesce(p_event->'decks', '[]'::jsonb)) with ordinality d(v, n)
    cross join lateral (values (false, d.v->'main'), (true, d.v->'side')) s(side, lines)
    cross join lateral jsonb_array_elements(coalesce(s.lines, '[]'::jsonb)) l
   where coalesce((l->>1)::integer, 0) > 0;
  update meta_lines m set id = c.id
    from (select distinct name, t1_private.meta_card_id(name) id from meta_lines) c where c.name = m.name;

  insert into t1_private.meta_unmatched as u (source, name)
  select distinct p_event->>'source', name from meta_lines where id is null
  on conflict (source, name) do update set seen = u.seen + 1, last_seen = current_date;
  select count(distinct name) into v_unmatched from meta_lines where id is null;

  insert into t1_private.meta_decks (event_id, format, on_date, tier, weight, player, rank, wins, losses, draws, top8,
                                     main, main_qty, side, side_qty)
  select v_event, v_format, (p_event->>'on')::date, v_tier,
         t.weight * case when coalesce((d.v->>'top8')::boolean, false) then v_set.top8_factor else 1 end,
         encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || coalesce(d.v->>'player', d.n::text), 'sha256'), 'hex'),
         nullif(d.v->>'rank', '')::integer, nullif(d.v->>'wins', '')::integer, nullif(d.v->>'losses', '')::integer,
         nullif(d.v->>'draws', '')::integer, coalesce((d.v->>'top8')::boolean, false),
         coalesce(m.ids, '{}'), coalesce(m.qty, '{}'), coalesce(s.ids, '{}'), coalesce(s.qty, '{}')
    from jsonb_array_elements(coalesce(p_event->'decks', '[]'::jsonb)) with ordinality d(v, n)
    cross join t1_private.meta_tiers t
    left join lateral (select array_agg(id order by id) ids, array_agg(q::smallint order by id) qty
                         from (select id, sum(qty) q from meta_lines where n = d.n and not side and id is not null group by id) x) m on true
    left join lateral (select array_agg(id order by id) ids, array_agg(q::smallint order by id) qty
                         from (select id, sum(qty) q from meta_lines where n = d.n and side and id is not null group by id) x) s on true
   where t.tier = v_tier;
  get diagnostics v_decks = row_count;

  update t1_private.meta_decks set colors = t1_private.meta_colors(main, main_qty),
         archetype_id = t1_private.meta_label(format, main, side)
   where event_id = v_event;

  insert into t1_private.meta_matches (event_id, round, a, b, a_wins, b_wins, result)
  select distinct on (m->>'round', da.id, db.id) v_event, m->>'round', da.id, db.id,
         nullif(m->>'a_wins', '')::integer, nullif(m->>'b_wins', '')::integer, m->>'result'
    from jsonb_array_elements(coalesce(p_event->'matches', '[]'::jsonb)) m
    join t1_private.meta_decks da on da.event_id = v_event
     and da.player = encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || (m->>'a'), 'sha256'), 'hex')
    join t1_private.meta_decks db on db.event_id = v_event
     and db.player = encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || (m->>'b'), 'sha256'), 'hex')
   where m->>'result' in ('a', 'b', 'draw') and da.id <> db.id;

  return jsonb_build_object('event_id', v_event, 'tier', v_tier, 'decks', v_decks, 'unmatched', v_unmatched);
end $$;

-- ==================================================================== f_pack_facts
-- Windows end at p_through (the pack's last day). Shares are weighted: tier weight, ×2 for a top-8 finish.

create or replace function public.meta_pack_window(p_format text, p_tier text, p_days integer, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with cur as (
    select d.* from t1_private.meta_decks d
     where d.format = p_format and d.on_date > p_through - p_days and d.on_date <= p_through
       and t1_private.meta_tier_in(d.tier, p_tier)),
  prv as (
    select d.* from t1_private.meta_decks d
     where d.format = p_format and d.on_date > p_through - 2 * p_days and d.on_date <= p_through - p_days
       and t1_private.meta_tier_in(d.tier, p_tier)),
  tot as (select coalesce(sum(weight), 0) w, count(*) n, count(distinct event_id) e from cur),
  ptot as (select coalesce(sum(weight), 0) w from prv),
  sh as (select archetype_id a, sum(weight) w, count(*) n, count(*) filter (where top8) t8 from cur group by 1),
  psh as (select archetype_id a, sum(weight) w from prv group by 1),
  -- conversion only from events whose whole field is known
  cv as (select d.archetype_id a, count(*) n, count(*) filter (where d.top8) t8
           from cur d join t1_private.meta_events e on e.id = d.event_id and e.complete group by 1),
  cvt as (select sum(n) n, sum(t8) t8 from cv),
  cards as (
    select 'cur' w, s.side, u.id, sum(d.weight) wt, sum(d.weight * u.q) wq
      from cur d cross join lateral (values (false, d.main, d.main_qty), (true, d.side, d.side_qty)) s(side, ids, qty)
      cross join lateral unnest(s.ids, s.qty) u(id, q) group by 1, 2, 3
    union all
    select 'prv', s.side, u.id, sum(d.weight), sum(d.weight * u.q)
      from prv d cross join lateral (values (false, d.main, d.main_qty), (true, d.side, d.side_qty)) s(side, ids, qty)
      cross join lateral unnest(s.ids, s.qty) u(id, q) group by 1, 2, 3),
  rates as (
    select c.side, c.id,
           coalesce(max(c.wt) filter (where c.w = 'cur'), 0) / nullif((select w from tot), 0) rate,
           coalesce(max(c.wt) filter (where c.w = 'prv'), 0) / nullif((select w from ptot), 0) prev,
           max(c.wq / c.wt) filter (where c.w = 'cur') copies
      from cards c group by 1, 2),
  ranked as (
    select r.*, o.name, r.rate - coalesce(r.prev, 0) delta from rates r
      join public.card_oracles o on o.oracle_id = r.id
     where coalesce(o.type_line, '') !~ 'Land' and greatest(r.rate, coalesce(r.prev, 0)) >= 0.03),
  card_json as (
    select side, dir, jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'prev', round(prev, 4),
                                                   'copies', round(copies, 2)) order by ord) j
      from (select r.*, 'up' dir, row_number() over (partition by side order by delta desc, name) ord from ranked r where delta > 0
            union all
            select r.*, 'down', row_number() over (partition by side order by delta, name) from ranked r where delta < 0) x
     where ord <= 12 group by 1, 2)
  select jsonb_build_object(
    'decks', (select n from tot), 'weighted', round((select w from tot), 1), 'events', (select e from tot),
    'thin', (select w from tot) < (select thin_below from t1_private.meta_settings),
    'share', coalesce((select jsonb_agg(jsonb_build_object(
                 'a', sh.a, 'share', round(sh.w / nullif((select w from tot), 0), 4),
                 'prev', round(coalesce(psh.w, 0) / nullif((select w from ptot), 0), 4),
                 'decks', sh.n, 'top8', sh.t8,
                 'conv', case when cv.n >= 20 and cvt.t8 > 0   -- a handful of decks says nothing about converting
                              then round((cv.t8::numeric / cvt.t8) / (cv.n::numeric / cvt.n), 2) end)
               order by sh.w desc, sh.a)
             from sh left join psh on psh.a = sh.a left join cv on cv.a = sh.a cross join cvt), '[]'::jsonb),
    'cards', jsonb_build_object(
      'main', jsonb_build_object('up', coalesce((select j from card_json where not side and dir = 'up'), '[]'),
                                 'down', coalesce((select j from card_json where not side and dir = 'down'), '[]')),
      'side', jsonb_build_object('up', coalesce((select j from card_json where side and dir = 'up'), '[]'),
                                 'down', coalesce((select j from card_json where side and dir = 'down'), '[]'))));
$$;

-- Daily 7-day rolling weighted share over p_days, for the 8 archetypes with the largest 30-day share.
create or replace function public.meta_pack_series(p_format text, p_tier text, p_days integer default 180, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with days as (select (p_through - p_days + 1 + g)::date d, g from generate_series(0, p_days - 1) g),
  span as (
    select d.on_date, d.archetype_id a, d.weight from t1_private.meta_decks d
     where d.format = p_format and d.on_date > p_through - p_days - 6 and d.on_date <= p_through
       and t1_private.meta_tier_in(d.tier, p_tier)),
  top as (
    select a from span where on_date > p_through - 30 group by a order by sum(weight) desc, a limit 8),
  daily as (
    select days.d, days.g,
           (select coalesce(sum(s.weight), 0) from span s where s.on_date > days.d - 7 and s.on_date <= days.d) tot
      from days),
  lines as (
    select t.a, dl.g,
           case when dl.tot > 0 then round((select coalesce(sum(s.weight), 0) from span s
                                             where s.a = t.a and s.on_date > dl.d - 7 and s.on_date <= dl.d) / dl.tot, 4) end v
      from top t cross join daily dl)
  select jsonb_build_object(
    'from', (p_through - p_days + 1)::text, 'days', p_days,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'v', v) order by first_share desc, a)
                         from (select l.a, jsonb_agg(l.v order by l.g) v,
                                      (select sum(weight) from span s where s.a = l.a and s.on_date > p_through - 30) first_share
                                 from lines l group by l.a) x), '[]'::jsonb),
    'other', (select jsonb_agg(case when dl.tot > 0 then round(1 - coalesce((select sum(s.weight) from span s
                                    where s.a in (select a from top) and s.on_date > dl.d - 7 and s.on_date <= dl.d), 0) / dl.tot, 4) end
                               order by dl.g) from daily dl));
$$;

-- The newest expansion/core/draft-innovation set that brought at least 10 new cards legal in the format, and those
-- cards ranked by how many decks play them since its release (at most 90 days).
create or replace function public.meta_pack_new_set(p_format text, p_tier text, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with s as (
    select ms.code, ms.name, ms.released_at from public.mtg_sets ms
     where ms.set_type in ('expansion', 'core', 'draft_innovation') and not ms.digital and ms.released_at <= p_through
       and ms.released_at > p_through - 400
       and (select count(distinct c.oracle_id) from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
             where c.set_code = ms.code and o.legalities->>p_format in ('legal', 'restricted')
               and not exists (select 1 from public.cards c2 where c2.oracle_id = c.oracle_id and c2.released_at < ms.released_at)) >= 10
     order by ms.released_at desc limit 1),
  fresh as (
    select c.oracle_id from public.cards c, s where c.set_code = s.code
     group by c.oracle_id
    having not exists (select 1 from public.cards c2 where c2.oracle_id = c.oracle_id and c2.released_at < (select released_at from s))),
  dk as (
    select d.* from t1_private.meta_decks d, s
     where d.format = p_format and d.on_date >= s.released_at and d.on_date > p_through - 90 and d.on_date <= p_through
       and t1_private.meta_tier_in(d.tier, p_tier)),
  tot as (select sum(weight) w from dk),
  play as (
    select u.id, sum(d.weight) w, sum(d.weight * u.q) wq,
           (select array_agg(a order by aw desc) from (
               select d2.archetype_id a, sum(d2.weight) aw from dk d2
                where u.id = any(d2.main) or u.id = any(d2.side) group by 1 order by 2 desc limit 3) t) arch
      from dk d cross join lateral unnest(d.main || d.side, d.main_qty || d.side_qty) u(id, q)
     where u.id in (select oracle_id from fresh)
     group by u.id)
  select case when (select code from s) is null then null else jsonb_build_object(
    'set_code', (select code from s), 'name', (select name from s), 'released', (select released_at::text from s),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('c', p.id, 'n', o.name, 'rate', round(p.w / nullif((select w from tot), 0), 4),
                                                       'copies', round(p.wq / p.w, 2), 'in', to_jsonb(p.arch))
                                      order by p.w desc, o.name)
                         from (select * from play order by w desc limit 12) p join public.card_oracles o on o.oracle_id = p.id), '[]'::jsonb))
  end;
$$;

-- Ban studies: every confirmed ban/unban/restrict/unrestrict in the last 365 days, newest first (All events).
-- daily carries the 7-day rolling shares after the change (up to 90 days) for meta-sync to find settled_days; it
-- isn't published.
create or replace function public.meta_pack_bans(p_format text, p_through date default current_date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  ch t1_private.meta_format_changes;
  v_out jsonb := '[]'::jsonb;
  v_ids uuid[];
  v_after_days integer;
  v_study jsonb;
begin
  for ch in select * from t1_private.meta_format_changes
             where format = p_format and status = 'confirmed' and kind in ('ban', 'unban', 'restrict', 'unrestrict')
               and on_date > p_through - 365 and on_date <= p_through
             order by on_date desc, id desc loop
    select coalesce(array_agg(t1_private.meta_card_id(x)) filter (where t1_private.meta_card_id(x) is not null), '{}')
      into v_ids from unnest(ch.cards) x;
    v_after_days := least(60, p_through - ch.on_date + 1);
    with dk as (
      select d.*, case when d.on_date < ch.on_date then 'before' else 'after' end w,
             (d.main || d.side) && v_ids has_card
        from t1_private.meta_decks d
       where d.format = p_format and d.on_date >= ch.on_date - 30 and d.on_date < ch.on_date + v_after_days),
    tot as (select w, sum(weight) t from dk group by w),
    sh as (select dk.w, dk.archetype_id a, sum(dk.weight) / max(tot.t) s from dk join tot using (w) group by 1, 2),
    held as (select archetype_id a, sum(weight) filter (where has_card) / sum(weight) frac from dk where w = 'before' and archetype_id <> 0 group by 1),
    losers as (
      select h.a, coalesce(b.s, 0) bs, coalesce(af.s, 0) afs from held h
        left join sh b on b.a = h.a and b.w = 'before' left join sh af on af.a = h.a and af.w = 'after'
       where ch.kind in ('ban', 'restrict') and h.frac >= 0.5 and coalesce(b.s, 0) >= 0.01),
    gainers as (
      select coalesce(af.a, b.a) a, coalesce(b.s, 0) bs, coalesce(af.s, 0) afs
        from (select * from sh where w = 'after') af full join (select * from sh where w = 'before') b on b.a = af.a
       where coalesce(af.a, b.a) not in (select a from losers) and coalesce(af.a, b.a) <> 0 and coalesce(af.s, 0) > coalesce(b.s, 0)
       order by coalesce(af.s, 0) - coalesce(b.s, 0) desc limit 3),
    -- Losers: cards whose play rate in the loser's decks rose most. Unbans: the unbanned cards by archetype.
    lt as (
      select archetype_id a, sum(weight) filter (where w = 'before') bt, sum(weight) filter (where w = 'after') at
        from dk where archetype_id in (select a from losers) group by 1),
    repl as (
      select x.* from (
        select l.a, u.id,
               coalesce(sum(dk.weight) filter (where dk.w = 'before'), 0) / nullif(max(lt.bt), 0) bf,
               coalesce(sum(dk.weight) filter (where dk.w = 'after'), 0) / nullif(max(lt.at), 0) af
          from losers l
          join lt on lt.a = l.a
          join dk on dk.archetype_id = l.a
          cross join lateral unnest(dk.main) u(id)
         where not (u.id = any(v_ids))
         group by l.a, u.id) x
       where x.af is not null and not t1_private.meta_is_basic(x.id)),
    repl_top as (select * from (select r.*, row_number() over (partition by a order by af - coalesce(bf, 0) desc) rn from repl r) y where rn <= 3),
    adopt as (
      select dk.archetype_id a, u.id, sum(dk.weight) / nullif((select sum(weight) from dk d2 where d2.w = 'after' and d2.archetype_id = dk.archetype_id), 0) af
        from dk cross join lateral unnest(dk.main || dk.side) u(id)
       where ch.kind in ('unban', 'unrestrict') and dk.w = 'after' and dk.archetype_id <> 0 and u.id = any(v_ids)
       group by 1, 2 order by 3 desc limit 5),
    win_after as (
      select n, (select jsonb_agg(jsonb_build_object('a', a, 'share', round(s, 4)) order by s desc) from (
                   select * from (select d.archetype_id a, sum(d.weight) / sum(sum(d.weight)) over () s
                                    from t1_private.meta_decks d
                                   where d.format = p_format and d.on_date >= ch.on_date and d.on_date < ch.on_date + n
                                   group by 1) x where s >= 0.005 order by s desc limit 20) t) j
        from unnest(array[14, 30, 60]) n where ch.on_date + n - 1 <= p_through),
    top_after as (select a from sh where w = 'after' order by s desc limit 8),
    days as (select (ch.on_date + g)::date d, g from generate_series(0, least(89, p_through - ch.on_date)) g),
    roll as (
      select t.a, dd.g,
             (select sum(d.weight) filter (where d.archetype_id = t.a) / nullif(sum(d.weight), 0)
                from t1_private.meta_decks d
               where d.format = p_format and d.on_date > dd.d - 7 and d.on_date <= dd.d) v
        from top_after t cross join days dd)
    select jsonb_build_object(
      'change', ch.id, 'on', ch.on_date::text,
      'before', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'share', round(s, 4)) order by s desc)
                            from (select a, s from sh where w = 'before' and s >= 0.005 order by s desc limit 20) b), '[]'::jsonb),
      'after', coalesce((select jsonb_object_agg(n::text, coalesce(j, '[]'::jsonb)) from win_after), '{}'::jsonb),
      'after_days', v_after_days,
      'losers', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'before', round(bs, 4), 'after', round(afs, 4)) order by bs desc) from losers), '[]'::jsonb),
      'gainers', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'before', round(bs, 4), 'after', round(afs, 4)) order by afs - bs desc) from gainers), '[]'::jsonb),
      'replacements', coalesce((
        select jsonb_agg(jsonb_build_object('c', r.id, 'n', o.name, 'before', round(coalesce(r.bf, 0), 4), 'after', round(r.af, 4), 'in', r.a)
                         order by r.a, r.af - coalesce(r.bf, 0) desc)
          from (select a, id, bf, af from repl_top union all select a, id, 0, af from adopt) r
          join public.card_oracles o on o.oracle_id = r.id), '[]'::jsonb),
      'daily', jsonb_build_object('from', ch.on_date::text, 'lines', coalesce((
        select jsonb_agg(jsonb_build_object('a', a, 'v', v)) from (
          select a, jsonb_agg(round(v, 4) order by g) v from roll group by a) x), '[]'::jsonb)))
      into v_study;
    v_out := v_out || jsonb_build_array(v_study);
  end loop;
  return v_out;
end $$;

-- Matchups over 90 days between the 10 archetypes with the largest 90-day share (All events).
create or replace function public.meta_pack_matchups(p_format text, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with top as (
    select archetype_id a, row_number() over (order by sum(weight) desc, archetype_id) pos
      from t1_private.meta_decks
     where format = p_format and on_date > p_through - 90 and on_date <= p_through and archetype_id <> 0
     group by archetype_id order by sum(weight) desc, archetype_id limit 10),
  m as (
    select ta.pos pa, tb.pos pb, ta.a aa, tb.a ab, mm.result
      from t1_private.meta_matches mm
      join t1_private.meta_decks da on da.id = mm.a
      join t1_private.meta_decks db on db.id = mm.b
      join top ta on ta.a = da.archetype_id
      join top tb on tb.a = db.archetype_id
     where da.format = p_format and da.on_date > p_through - 90 and da.on_date <= p_through and ta.a <> tb.a),
  o as (  -- orient each match so the first archetype is the one listed first
    select least(pa, pb) p1, greatest(pa, pb) p2,
           case when pa < pb then aa else ab end x, case when pa < pb then ab else aa end y,
           case when result = 'draw' then 'draw' when (result = 'a') = (pa < pb) then 'x' else 'y' end r
      from m)
  select jsonb_build_object(
    'archetypes', coalesce((select jsonb_agg(a order by pos) from top), '[]'::jsonb),
    'cells', coalesce((select jsonb_agg(jsonb_build_array(x, y, xw, yw, dr) order by p1, p2) from (
        select p1, p2, x, y, count(*) filter (where r = 'x') xw, count(*) filter (where r = 'y') yw,
               count(*) filter (where r = 'draw') dr
          from o group by p1, p2, x, y) c), '[]'::jsonb));
$$;

-- Archetypes, confirmed format changes, recent big events and which tier the client opens on.
create or replace function public.meta_pack_base(p_format text, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'format', f.format, 'name', f.name, 'through', p_through::text,
    'sources', coalesce((select jsonb_agg(distinct e.source) from t1_private.meta_events e
                          where e.format = f.format and e.on_date > p_through - 90), '[]'::jsonb),
    'default_tier', case when coalesce((select sum(weight) from t1_private.meta_decks d
                                         where d.format = f.format and d.on_date > p_through - 30 and d.on_date <= p_through
                                           and d.tier in ('major', 'large')), 0)
                              >= (select thin_below from t1_private.meta_settings) then 'big' else 'all' end,
    'archetypes', jsonb_build_array(jsonb_build_object('id', 0, 'name', 'Other', 'family', 'midrange', 'colors', ''))
                  || coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'family', a.family, 'colors', a.colors) order by a.name)
                                 from t1_private.meta_archetypes a where a.format = f.format and a.status = 'approved'), '[]'::jsonb),
    'changes', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'on', c.on_date::text, 'kind', c.kind, 'cards', to_jsonb(c.cards),
                                                             'set_code', c.set_code, 'note', c.note, 'url', c.url) order by c.on_date, c.id)
                           from t1_private.meta_format_changes c
                          where c.format = f.format and c.status = 'confirmed' and c.on_date > p_through - 365 and c.on_date <= p_through), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(ev order by ord, on_date desc, players desc nulls last) from (
        select e.on_date, e.players, t.ord,
               jsonb_build_object('name', e.name, 'on', e.on_date::text, 'players', e.players, 'tier', e.tier, 'source', e.source, 'url', e.url,
                 'top8', (select jsonb_agg(d.archetype_id order by d.rank nulls last, d.id) from (
                            select * from t1_private.meta_decks d where d.event_id = e.id and d.top8 order by d.rank nulls last, d.id limit 8) d),
                 'winner', (select d.archetype_id from t1_private.meta_decks d where d.event_id = e.id and d.rank = 1 limit 1)) ev
          from t1_private.meta_events e join t1_private.meta_tiers t on t.tier = e.tier
         where e.format = f.format and e.kind <> 'league' and e.on_date > p_through - 30 and e.on_date <= p_through
         order by t.ord, e.on_date desc limit 40) x), '[]'::jsonb))
  from t1_private.meta_formats f where f.format = p_format;
$$;

-- ==================================================================== g_clustering
-- Decks labelled Other in the last p_days, as nonland main-deck Oracle ids, with names for the prompt.
create or replace function public.meta_cluster_input(p_format text, p_days integer default 45)
returns jsonb language sql stable security definer set search_path = '' as $$
  with dk as (
    select d.id, d.colors, array(select u from unnest(d.main) u
                                  join public.card_oracles o on o.oracle_id = u
                                 where coalesce(o.type_line, '') !~ 'Land') cards
      from t1_private.meta_decks d
     where d.format = p_format and d.archetype_id = 0 and d.on_date > current_date - p_days),
  ids as (select distinct unnest(cards) id from dk)
  select jsonb_build_object(
    'total', (select count(*) from t1_private.meta_decks where format = p_format and on_date > current_date - p_days),
    'decks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'colors', colors, 'cards', to_jsonb(cards))) from dk), '[]'::jsonb),
    'names', coalesce((select jsonb_object_agg(o.oracle_id, o.name) from ids join public.card_oracles o on o.oracle_id = ids.id), '{}'::jsonb),
    'known', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'status', status, 'signature', to_jsonb(signature)))
                         from t1_private.meta_archetypes where format = p_format), '[]'::jsonb));
$$;

-- A proposed archetype from clustering (shown on Review, never used until approved). Null when the name is taken.
create or replace function public.meta_archetype_propose(p_format text, p_name text, p_family text, p_colors text,
                                                         p_rule jsonb, p_signature text[], p_decks integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_id integer;
begin
  insert into t1_private.meta_archetypes (format, name, family, colors, status, rule, priority, source, signature, sample_decks)
  values (p_format, left(trim(p_name), 60), p_family, coalesce(p_colors, ''), 'proposed', p_rule, 100, 'claude', p_signature, p_decks)
  on conflict (format, name) do nothing
  returning id into v_id;
  return v_id;
end $$;

-- ==================================================================== h_briefs_packs
create or replace function public.insight_brief_get(p_view text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('facts_hash', facts_hash, 'brief', brief) from t1_private.insight_briefs where view = p_view;
$$;

create or replace function public.insight_brief_put(p_view text, p_hash text, p_brief text, p_model text)
returns void language sql security definer set search_path = '' as $$
  insert into t1_private.insight_briefs (view, facts_hash, brief, model) values (p_view, p_hash, p_brief, p_model)
  on conflict (view) do update set facts_hash = excluded.facts_hash, brief = excluded.brief, model = excluded.model, created_at = now();
$$;

create or replace function public.insight_pack_publish(p_kind text, p_key text, p_name text, p_ord integer, p_version text,
                                                       p_path text, p_bytes integer, p_sha256 text, p_through date)
returns void language sql security definer set search_path = '' as $$
  insert into t1_private.insight_packs (kind, key, name, ord, version, path, bytes, sha256, through)
  values (p_kind, p_key, p_name, p_ord, p_version, p_path, p_bytes, p_sha256, p_through)
  on conflict (kind, key) do update set name = excluded.name, ord = excluded.ord, version = excluded.version, path = excluded.path,
    bytes = excluded.bytes, sha256 = excluded.sha256, through = excluded.through, built_at = now();
$$;

create or replace function public.insight_pack_current(p_kind text, p_key text)
returns text language sql stable security definer set search_path = '' as $$
  select version from t1_private.insight_packs where kind = p_kind and key = p_key;
$$;

-- ==================================================================== i_legality
create or replace function t1_private.meta_legality_changed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into t1_private.meta_legality_log (oracle_id, format, before, after)
  select new.oracle_id, f.format, old.legalities->>f.format, new.legalities->>f.format
    from t1_private.meta_formats f
   where (old.legalities->>f.format) is distinct from (new.legalities->>f.format)
  on conflict (oracle_id, format, seen) do update set after = excluded.after;
  return null;
end $$;
drop trigger if exists card_oracles_meta_legality on public.card_oracles;
create trigger card_oracles_meta_legality after update of legalities on public.card_oracles
  for each row when (old.legalities is distinct from new.legalities)
  execute function t1_private.meta_legality_changed();

-- Groups the day's legality changes into proposed format changes (a moderator confirms them), and adds the
-- releases of recent sets with cards legal in each format (confirmed: they come from Scryfall's set data).
create or replace function t1_private.meta_legality_propose()
returns void language plpgsql security definer set search_path = '' as $$
begin
  with x as (
    select l.format, l.seen,
           case when l.after = 'banned' then 'ban'
                when l.before = 'banned' then 'unban'
                when l.after = 'restricted' then 'restrict'
                when l.before = 'restricted' and l.after = 'legal' then 'unrestrict'
                when l.before = 'legal' and l.after is null then 'rotation' end kind,
           o.name
      from t1_private.meta_legality_log l join public.card_oracles o on o.oracle_id = l.oracle_id
     where not l.proposed),
  g as (select format, seen, kind, array_agg(name order by name) cards from x where kind is not null group by 1, 2, 3)
  insert into t1_private.meta_format_changes (format, on_date, kind, cards, status, note)
  select format, seen, kind, cards, 'proposed', 'From the catalog''s daily legality check'
    from g where kind <> 'rotation' or cardinality(cards) >= 50
  on conflict (format, on_date, kind, set_code) do nothing;
  update t1_private.meta_legality_log set proposed = true where not proposed;

  insert into t1_private.meta_format_changes (format, on_date, kind, set_code, cards, status, note)
  select f.format, s.released_at, 'set_release', s.code, '{}', 'confirmed', s.name
    from public.mtg_sets s cross join t1_private.meta_formats f
   where s.set_type in ('expansion', 'core', 'draft_innovation') and not s.digital
     and s.released_at between current_date - 400 and current_date
     and exists (select 1 from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
                  where c.set_code = s.code and o.legalities->>f.format in ('legal', 'restricted') limit 1)
  on conflict (format, on_date, kind, set_code) do nothing;
end $$;

-- ==================================================================== j_limited
-- Sets that may be on Arena with a 17Lands dump: released in the last 300 days (or announced as releasing soon).
create or replace function public.limited_candidates()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('set_code', upper(code), 'name', name, 'released', released_at::text) order by released_at desc), '[]'::jsonb)
    from public.mtg_sets
   where set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'alchemy', 'remastered')
     and released_at between current_date - 300 and current_date + 7;
$$;

-- Opens a run for a dump the server hasn't read at this Last-Modified; null when it has (or one is in flight).
create or replace function public.limited_run_open(p_set text, p_event text, p_kind text, p_uri text, p_last_modified timestamptz, p_total bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  if exists (select 1 from t1_private.limited_runs where set_code = upper(p_set) and event_type = p_event and kind = p_kind
               and last_modified >= p_last_modified and status in ('pending', 'running', 'done')) then
    return null;
  end if;
  update t1_private.limited_runs set status = 'superseded', finished_at = now()
   where set_code = upper(p_set) and event_type = p_event and kind = p_kind and status in ('pending', 'running', 'failed');
  insert into t1_private.limited_runs (set_code, event_type, kind, uri, last_modified, total_bytes)
  values (upper(p_set), p_event, p_kind, p_uri, p_last_modified, p_total)
  on conflict (set_code, event_type, kind, last_modified) do update set status = 'pending', step = 0, bit = null, win = null,
    carry = null, header = null, rows = 0, error = null, attempts = 0
  returning id into v_id;
  delete from t1_private.limited_acc where run_id = v_id;
  return v_id;
end $$;

create or replace function public.limited_run_state(p_run bigint)
returns jsonb language sql security definer set search_path = '' as $$
  update t1_private.limited_runs set status = 'running', in_flight_at = now(), attempts = attempts + 1
   where id = p_run and status in ('pending', 'running')
  returning jsonb_build_object('id', id, 'set_code', set_code, 'event_type', event_type, 'kind', kind, 'uri', uri,
    'total_bytes', total_bytes, 'step', step, 'bit', bit, 'win', coalesce(win, ''), 'carry', coalesce(carry, ''), 'header', header,
    'released', (select s.released_at::text from public.mtg_sets s where s.code = lower(set_code)));
$$;

-- Adds one slice's sums and moves the run on, in one transaction; a step that was already committed is ignored.
create or replace function public.limited_step_commit(p_run bigint, p_step integer, p_bit bigint, p_window text, p_carry text,
                                                      p_header jsonb, p_rows integer, p_acc jsonb, p_final boolean)
returns text language plpgsql security definer set search_path = '' as $$
declare v t1_private.limited_runs;
begin
  select * into v from t1_private.limited_runs where id = p_run for update;
  if v.id is null or v.status <> 'running' then return 'gone'; end if;
  if v.step <> p_step then return 'stale'; end if;
  insert into t1_private.limited_acc as a (run_id, k, g, w)
  select p_run, e.key, coalesce((e.value->>0)::bigint, 0), coalesce((e.value->>1)::bigint, 0)
    from jsonb_each(coalesce(p_acc, '{}'::jsonb)) e
  on conflict (run_id, k) do update set g = a.g + excluded.g, w = a.w + excluded.w;
  update t1_private.limited_runs set step = step + 1, bit = p_bit, win = p_window, carry = p_carry,
         header = coalesce(header, p_header), rows = rows + coalesce(p_rows, 0), in_flight_at = null, attempts = 0, error = null,
         status = case when p_final then 'done' else 'running' end,
         finished_at = case when p_final then now() end
   where id = p_run;
  return case when p_final then 'done' else 'next' end;
end $$;

create or replace function public.limited_run_fail(p_run bigint, p_error text)
returns void language sql security definer set search_path = '' as $$
  update t1_private.limited_runs set error = left(p_error, 500), in_flight_at = null,
         status = case when attempts >= 3 then 'failed' else status end
   where id = p_run;
$$;

-- Card facts by name from the catalog: Oracle id, rarity in the set, colours.
create or replace function t1_private.limited_card(p_set text, p_name text)
returns table (oracle_id uuid, rarity text, col text) language sql stable set search_path = '' as $$
  select o.oracle_id,
         (select c.rarity from public.cards c where c.oracle_id = o.oracle_id and c.set_code = lower(p_set)
           order by array_position(array['common', 'uncommon', 'rare', 'mythic', 'special', 'bonus'], c.rarity) limit 1),
         case when cardinality(o.colors) = 0 then 'C'
              else (select string_agg(x, '' order by position(x in 'WUBRG')) from unnest(o.colors) x) end
    from public.card_oracles o where o.oracle_id = t1_private.meta_card_id(p_name);
$$;

-- One group's view of a set and event from the latest finished game run (and draft run for ATA).
create or replace function t1_private.limited_view(p_game bigint, p_draft bigint, p_grp text, p_set text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_tot record;
  v_weeks integer;
  v jsonb;
begin
  select g, w into v_tot from t1_private.limited_acc where run_id = p_game and k = 'T|' || p_grp;
  if v_tot.g is null or v_tot.g = 0 then return null; end if;
  select coalesce(max(split_part(k, '|', 3)::integer), 0) into v_weeks
    from t1_private.limited_acc where run_id = p_game and k like 'pw|%' and split_part(k, '|', 4) = p_grp;
  with acc as (select k, g, w, split_part(k, '|', 1) t, split_part(k, '|', 2) a, split_part(k, '|', 3) b, split_part(k, '|', 4) c
                 from t1_private.limited_acc where run_id = p_game),
  pairs as (
    select a p, g, w from acc where t = 'p' and b = p_grp),
  cards as (
    select a n,
           max(g) filter (where t = 'cd' and b = p_grp) deck_g,
           max(g) filter (where t = 'ch' and b = p_grp) ch_g, max(w) filter (where t = 'ch' and b = p_grp) ch_w,
           max(g) filter (where t = 'co' and b = p_grp) co_g, max(w) filter (where t = 'co' and b = p_grp) co_w,
           max(g) filter (where t = 'cg' and b = p_grp) cg_g, max(w) filter (where t = 'cg' and b = p_grp) cg_w,
           max(g) filter (where t = 'cn' and b = p_grp) cn_g, max(w) filter (where t = 'cn' and b = p_grp) cn_w
      from acc where t in ('cd', 'ch', 'co', 'cg', 'cn') group by a)
  select jsonb_build_object(
    'games', v_tot.g, 'wr', round(v_tot.w::numeric / v_tot.g, 4), 'weeks', v_weeks,
    'pairs', coalesce((select jsonb_agg(jsonb_build_object(
        'p', p.p, 'games', p.g, 'wr', round(p.w::numeric / nullif(p.g, 0), 4), 'share', round(p.g::numeric / v_tot.g, 4),
        'splash', round(coalesce((select g from acc where t = 'ps' and a = p.p and b = p_grp), 0)::numeric / nullif(p.g, 0), 4),
        'play_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'pp' and a = p.p and b = p_grp),
        'draw_wr', (select round((p.w - w)::numeric / nullif(p.g - g, 0), 4) from acc where t = 'pp' and a = p.p and b = p_grp),
        'week_wr', (select jsonb_agg((select round(w::numeric / nullif(g, 0), 4) from acc where t = 'pw' and a = p.p and b = wk::text and c = p_grp) order by wk)
                      from generate_series(1, greatest(v_weeks, 1)) wk),
        'week_share', (select jsonb_agg(round(coalesce((select g from acc where t = 'pw' and a = p.p and b = wk::text and c = p_grp), 0)::numeric
                                              / nullif((select sum(g) from acc where t = 'pw' and b = wk::text and c = p_grp), 0), 4) order by wk)
                         from generate_series(1, greatest(v_weeks, 1)) wk))
        order by p.g desc) from pairs p), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object(
        'c', lc.oracle_id, 'n', c.n, 'r', lc.rarity, 'col', lc.col,
        'gih', case when c.ch_g >= 500 then round(c.ch_w::numeric / c.ch_g, 4) end, 'gih_n', coalesce(c.ch_g, 0),
        'oh', case when c.ch_g >= 500 and c.co_g > 0 then round(c.co_w::numeric / c.co_g, 4) end,
        'gd', case when c.ch_g >= 500 and c.cg_g > 0 then round(c.cg_w::numeric / c.cg_g, 4) end,
        'gns', case when c.ch_g >= 500 and c.cn_g > 0 then round(c.cn_w::numeric / c.cn_g, 4) end,
        'iwd', case when c.ch_g >= 500 and c.cn_g > 0 then round(c.ch_w::numeric / c.ch_g - c.cn_w::numeric / c.cn_g, 4) end,
        'ata', (select round(w::numeric / nullif(g, 0), 2) from t1_private.limited_acc where run_id = p_draft and k = 'a|' || c.n || '|' || p_grp),
        'deck', round(coalesce(c.deck_g, 0)::numeric / v_tot.g, 4),
        'week_gih', case when p_grp = 'a' then (select jsonb_agg((select round(w::numeric / nullif(g, 0), 4) from acc
                                                                    where t = 'cw' and a = c.n and b = wk::text and g >= 200) order by wk)
                                                  from generate_series(1, greatest(v_weeks, 1)) wk) end,
        'pair_gih', case when p_grp = 'a' then (select coalesce(jsonb_object_agg(b, round(w::numeric / g, 4)), '{}'::jsonb)
                                                  from acc where t = 'cp' and a = c.n and g >= 200) end)
        order by c.ch_g desc nulls last, c.n)
        from cards c left join lateral t1_private.limited_card(p_set, c.n) lc on true
       where coalesce(c.deck_g, 0) > 0), '[]'::jsonb),
    -- every exact colour combination (main + splash) on 0.5% of games or more, most played first
    'colors', coalesce((select jsonb_agg(jsonb_build_object('m', a, 's', b, 'games', g, 'wr', round(w::numeric / g, 4),
                                                          'share', round(g::numeric / v_tot.g, 4)) order by g desc, a, b)
                          from acc where t = 'dc' and c = p_grp and g::numeric / v_tot.g >= 0.005), '[]'::jsonb),
    'facts', jsonb_build_object(
      'play_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'P' and a = p_grp),
      'draw_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'D' and a = p_grp),
      'mull_rate', (select round(g::numeric / v_tot.g, 4) from acc where t = 'M' and a = p_grp),
      'mull_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'M' and a = p_grp),
      'keep7_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'K' and a = p_grp),
      'mull_play', (select round(g::numeric / nullif((select g from acc where t = 'P' and a = p_grp), 0), 4) from acc where t = 'MP' and a = p_grp),
      'turns', (select round(w::numeric / nullif(g, 0), 1) from acc where t = 'N' and a = p_grp)))
  into v;
  return v;
end $$;

-- A set's whole pack (briefs are added by limited-sync), or null with no finished game run.
create or replace function public.limited_pack_facts(p_set text)
returns jsonb language sql stable security definer set search_path = '' as $$
  with latest as (
    select distinct on (event_type, kind) id, event_type, kind, last_modified
      from t1_private.limited_runs where set_code = upper(p_set) and status = 'done'
     order by event_type, kind, last_modified desc),
  ev as (
    select g.event_type, g.id game, d.id draft, g.last_modified
      from latest g left join latest d on d.event_type = g.event_type and d.kind = 'draft' where g.kind = 'game')
  select case when not exists (select 1 from ev) then null else jsonb_build_object(
    'v', 1, 'kind', 'limited', 'set_code', upper(p_set),
    'name', (select name from public.mtg_sets where code = lower(p_set)),
    'released', (select released_at::text from public.mtg_sets where code = lower(p_set)),
    'credit', jsonb_build_object('name', '17Lands', 'url', 'https://www.17lands.com/public_datasets'),
    'events', (select jsonb_object_agg(event_type, jsonb_build_object(
                  'updated', last_modified::date::text,
                  'groups', (select coalesce(jsonb_object_agg(g.k, g.v) filter (where g.v is not null), '{}'::jsonb)
                               from (values ('all', t1_private.limited_view(game, draft, 'a', p_set)),
                                            ('top', t1_private.limited_view(game, draft, 't', p_set))) g(k, v))))
                 from ev))
  end;
$$;

-- Next slice for the pg_cron tick: one run at a time, re-posted when its worker went quiet for 5 minutes.
create or replace function t1_private.limited_dispatch()
returns void language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  if exists (select 1 from t1_private.limited_runs where status = 'running' and in_flight_at > now() - interval '5 minutes') then
    return;
  end if;
  select id into v_id from t1_private.limited_runs where status in ('pending', 'running') and attempts < 4
   order by (status = 'running') desc, created_at limit 1;
  if v_id is null then return; end if;
  update t1_private.limited_runs set in_flight_at = now() where id = v_id;
  perform t1_private.insights_post('limited-sync', jsonb_build_object('step', 'slice', 'run', v_id));
end $$;

-- limited-sync calls this after each commit so the next slice starts at once rather than on the next tick.
create or replace function public.limited_kick()
returns void language sql security definer set search_path = '' as $$
  select t1_private.limited_dispatch();
$$;

-- ==================================================================== k_client_rpcs
create or replace function public.insights_index()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', p.kind, 'key', p.key, 'name', p.name, 'version', p.version,
           'url', 'https://aaozhfcbvqrgkkrihkrd.supabase.co/storage/v1/object/public/catalog/' || p.path,
           'bytes', p.bytes, 'built_at', p.built_at, 'through', p.through::text)
         order by p.kind, p.ord, p.key), '[]'::jsonb)
    from t1_private.insight_packs p
   where auth.uid() is not null;
$$;

create or replace function t1_private.meta_require(p_format text, p_tier text)
returns void language plpgsql stable set search_path = '' as $$
begin
  -- meta-sync reads archetypes as the service role to write their briefs
  if auth.uid() is null and auth.role() <> 'service_role' then
    raise exception 'Sign in to see Insights' using errcode = '28000';
  end if;
  if not exists (select 1 from t1_private.meta_formats where format = p_format and enabled) then
    raise exception 'Unknown format' using errcode = '22023';
  end if;
  if coalesce(p_tier, '') not in ('big', 'all') then raise exception 'Tier is big or all' using errcode = '22023'; end if;
end $$;

create or replace function public.meta_archetype(p_format text, p_archetype integer, p_tier text default 'all', p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_arch jsonb;
  v_days integer := case when p_days in (7, 14, 30, 90) then p_days else 30 end;
  v_out jsonb;
begin
  perform t1_private.meta_require(p_format, p_tier);
  if p_archetype = 0 then
    v_arch := jsonb_build_object('id', 0, 'name', 'Other', 'family', 'midrange', 'colors', '');
  else
    select jsonb_build_object('id', id, 'name', name, 'family', family, 'colors', colors) into v_arch
      from t1_private.meta_archetypes where id = p_archetype and format = p_format and status = 'approved';
  end if;
  if v_arch is null then raise exception 'Unknown archetype' using errcode = '22023'; end if;

  with win as (
    select d.* from t1_private.meta_decks d
     where d.format = p_format and d.on_date > current_date - v_days and t1_private.meta_tier_in(d.tier, p_tier)),
  mine as (select * from win where archetype_id = p_archetype),
  mt as (select coalesce(sum(weight), 0) w, count(*) n from mine),
  wins as (select count(*) n, count(*) filter (where top8) t8 from win d join t1_private.meta_events e on e.id = d.event_id and e.complete),
  mwins as (select count(*) n, count(*) filter (where top8) t8 from mine d join t1_private.meta_events e on e.id = d.event_id and e.complete),
  -- paper events' records cover the whole field, so when there are any they're the record; else MTGO's top 32
  recs as (
    select e.source, d.wins, d.losses, d.draws from mine d join t1_private.meta_events e on e.id = d.event_id
     where d.wins is not null and e.kind <> 'league'),
  rec as (
    select sum(wins) w, sum(losses) l, sum(coalesce(draws, 0)) dr, bool_or(source = 'topdeck') td
      from recs where source = 'topdeck' or not exists (select 1 from recs where source = 'topdeck')),
  lines as (
    select s.side, u.id, sum(m.weight) w, sum(m.weight * u.q) wq
      from mine m cross join lateral (values (false, m.main, m.main_qty), (true, m.side, m.side_qty)) s(side, ids, qty)
      cross join lateral unnest(s.ids, s.qty) u(id, q) group by 1, 2),
  rated as (
    select l.side, l.id, o.name, l.w / nullif((select w from mt), 0) rate, l.wq / l.w copies
      from lines l join public.card_oracles o on o.oracle_id = l.id where coalesce(o.type_line, '') !~ '^Basic'),
  weeks as (select g from generate_series(0, 25) g),
  series as (
    select w.g, (select sum(weight) filter (where d.archetype_id = p_archetype) / nullif(sum(weight), 0)
                   from t1_private.meta_decks d
                  where d.format = p_format and t1_private.meta_tier_in(d.tier, p_tier)
                    and d.on_date > current_date - 7 * (26 - w.g) and d.on_date <= current_date - 7 * (25 - w.g)) v
      from weeks w),
  mu as (
    select case when da.archetype_id = p_archetype then db.archetype_id else da.archetype_id end vs,
           count(*) filter (where (mm.result = 'a') = (da.archetype_id = p_archetype) and mm.result <> 'draw') wn,
           count(*) filter (where (mm.result = 'b') = (da.archetype_id = p_archetype) and mm.result <> 'draw') ls,
           count(*) filter (where mm.result = 'draw') dr
      from t1_private.meta_matches mm
      join t1_private.meta_decks da on da.id = mm.a join t1_private.meta_decks db on db.id = mm.b
     where da.format = p_format and da.on_date > current_date - 90
       and (da.archetype_id = p_archetype) <> (db.archetype_id = p_archetype)
     group by 1),
  fin as (
    select m.*, e.name ev, e.players, e.url from mine m join t1_private.meta_events e on e.id = m.event_id
     order by m.weight desc, m.rank nulls last, m.on_date desc limit 10)
  select jsonb_build_object(
    'archetype', v_arch,
    'decks', (select n from mt),
    'series', jsonb_build_object('from', (current_date - 7 * 26 + 1)::text, 'weeks', 26,
                                 'v', (select jsonb_agg(round(v, 4) order by g) from series)),
    'record', (select case when w is null then null else jsonb_build_object('wins', w, 'losses', l, 'draws', dr,
                 'basis', case when td then 'topdeck' else 'mtgo_top32' end) end from rec),
    'conv', (select case when wins.t8 > 0 and mwins.n >= 20 then round((mwins.t8::numeric / wins.t8) / (mwins.n::numeric / wins.n), 2) end from wins, mwins),
    'core', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from rated where not side and rate >= 0.8), '[]'::jsonb),
    'flex', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from (select * from rated where not side and rate >= 0.2 and rate < 0.8 order by rate desc limit 30) f), '[]'::jsonb),
    'side', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from (select * from rated where side and rate >= 0.2 order by rate desc limit 30) s), '[]'::jsonb),
    'matchups', coalesce((select jsonb_agg(jsonb_build_object('vs', vs, 'wins', wn, 'losses', ls, 'draws', dr) order by wn + ls + dr desc) from mu), '[]'::jsonb),
    'finishes', coalesce((select jsonb_agg(jsonb_build_object(
        'event', f.ev, 'on', f.on_date::text, 'players', f.players, 'tier', f.tier, 'rank', f.rank, 'url', f.url,
        'main', (select jsonb_agg(jsonb_build_array(o.name, u.q) order by o.cmc, o.name) from unnest(f.main, f.main_qty) u(id, q)
                   join public.card_oracles o on o.oracle_id = u.id),
        'side', coalesce((select jsonb_agg(jsonb_build_array(o.name, u.q) order by o.cmc, o.name) from unnest(f.side, f.side_qty) u(id, q)
                   join public.card_oracles o on o.oracle_id = u.id), '[]'::jsonb))
        order by f.weight desc, f.rank nulls last, f.on_date desc) from fin f), '[]'::jsonb),
    'brief', (select brief from t1_private.insight_briefs where view = 'arch:' || p_format || ':' || p_archetype))
  into v_out;
  return v_out;
end $$;

create or replace function public.meta_card(p_format text, p_oracle_id uuid, p_tier text default 'all')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform t1_private.meta_require(p_format, p_tier);
  with weeks as (select g from generate_series(0, 25) g),
  wk as (
    select w.g,
           (select sum(d.weight) filter (where p_oracle_id = any(d.main)) / nullif(sum(d.weight), 0)
              from t1_private.meta_decks d
             where d.format = p_format and t1_private.meta_tier_in(d.tier, p_tier)
               and d.on_date > current_date - 7 * (26 - w.g) and d.on_date <= current_date - 7 * (25 - w.g)) main,
           (select sum(d.weight) filter (where p_oracle_id = any(d.side)) / nullif(sum(d.weight), 0)
              from t1_private.meta_decks d
             where d.format = p_format and t1_private.meta_tier_in(d.tier, p_tier)
               and d.on_date > current_date - 7 * (26 - w.g) and d.on_date <= current_date - 7 * (25 - w.g)) side
      from weeks w),
  recent as (
    select d.* from t1_private.meta_decks d
     where d.format = p_format and d.on_date > current_date - 30 and t1_private.meta_tier_in(d.tier, p_tier)),
  holding as (
    select r.archetype_id a, r.weight,
           coalesce((select q from unnest(r.main || r.side, r.main_qty || r.side_qty) u(id, q) where u.id = p_oracle_id limit 1), 0) q
      from recent r),
  by_a as (
    select a, sum(weight) filter (where q > 0) / sum(weight) rate,
           sum(weight * q) filter (where q > 0) / nullif(sum(weight) filter (where q > 0), 0) copies
      from holding group by a having sum(weight) filter (where q > 0) > 0)
  select jsonb_build_object(
    'c', p_oracle_id, 'n', (select name from public.card_oracles where oracle_id = p_oracle_id),
    'series', jsonb_build_object('from', (current_date - 7 * 26 + 1)::text, 'weeks', 26,
                                 'main', (select jsonb_agg(round(main, 4) order by g) from wk),
                                 'side', (select jsonb_agg(round(side, 4) order by g) from wk)),
    'copies', (select round(sum(weight * q) / nullif(sum(weight), 0), 2) from holding where q > 0),
    'by_archetype', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc)
                                from (select * from by_a order by rate desc limit 8) b), '[]'::jsonb),
    'first_seen', (select min(on_date)::text from t1_private.meta_decks d
                    where d.format = p_format and (p_oracle_id = any(d.main) or p_oracle_id = any(d.side))))
  into v;
  return v;
end $$;

-- ==================================================================== l_review
create or replace function public.insights_review()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform t1_private.require_moderator();
  select jsonb_build_object(
    'archetypes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', a.id, 'format', a.format, 'name', a.name, 'family', a.family, 'colors', a.colors, 'rule', a.rule,
        'signature', to_jsonb(a.signature), 'decks', a.sample_decks, 'missing', to_jsonb(a.missing), 'blocked', a.blocked,
        'created_at', a.created_at)
        order by a.format, a.sample_decks desc nulls last)
        from t1_private.meta_archetypes a where a.status = 'proposed'), '[]'::jsonb),
    'changes', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'format', c.format, 'on', c.on_date::text, 'kind', c.kind,
        'cards', to_jsonb(c.cards), 'note', c.note) order by c.on_date desc)
        from t1_private.meta_format_changes c where c.status = 'proposed'), '[]'::jsonb),
    'unmatched', coalesce((select jsonb_agg(jsonb_build_object('source', u.source, 'name', u.name, 'seen', u.seen, 'last_seen', u.last_seen::text)
        order by u.seen desc) from (select * from t1_private.meta_unmatched order by seen desc limit 50) u), '[]'::jsonb))
  into v;
  return v;
end $$;

create or replace function public.insights_review_archetype(p_id integer, p_action text, p_name text default null, p_family text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.require_moderator();
  a t1_private.meta_archetypes;
begin
  select * into a from t1_private.meta_archetypes where id = p_id for update;
  if a.id is null then raise exception 'Unknown archetype' using errcode = '22023'; end if;
  if p_action not in ('approve', 'reject', 'rename') then raise exception 'approve, reject or rename' using errcode = '22023'; end if;
  if p_family is not null and p_family not in ('aggro', 'midrange', 'control', 'combo', 'ramp') then
    raise exception 'Unknown family' using errcode = '22023';
  end if;
  if nullif(trim(coalesce(p_name, '')), '') is not null and exists (
       select 1 from t1_private.meta_archetypes where format = a.format and name = trim(p_name) and id <> a.id) then
    raise exception 'That name is taken in %', a.format using errcode = '23505';
  end if;
  update t1_private.meta_archetypes set
    status = case p_action when 'approve' then 'approved' when 'reject' then 'rejected' else status end,
    name = coalesce(nullif(trim(coalesce(p_name, '')), ''), name),
    family = coalesce(p_family, family),
    source = case when p_name is not null or p_family is not null then 'john' else source end,
    updated_at = now()
   where id = p_id returning * into a;
  insert into t1_private.insights_audit (actor, action, target, detail)
  values (v_uid, 'archetype_' || p_action, a.format || ':' || a.id, jsonb_build_object('name', a.name, 'family', a.family));
  if p_action = 'approve' then perform public.meta_relabel(a.format); end if;
  return jsonb_build_object('id', a.id, 'status', a.status, 'name', a.name, 'family', a.family);
end $$;

create or replace function public.insights_review_change(p_id integer, p_action text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.require_moderator();
  c t1_private.meta_format_changes;
begin
  if p_action not in ('confirm', 'reject') then raise exception 'confirm or reject' using errcode = '22023'; end if;
  update t1_private.meta_format_changes set status = case p_action when 'confirm' then 'confirmed' else 'rejected' end
   where id = p_id returning * into c;
  if c.id is null then raise exception 'Unknown change' using errcode = '22023'; end if;
  insert into t1_private.insights_audit (actor, action, target, detail)
  values (v_uid, 'change_' || p_action, c.format || ':' || c.id, jsonb_build_object('kind', c.kind, 'on', c.on_date, 'cards', c.cards));
  return jsonb_build_object('id', c.id, 'status', c.status);
end $$;

-- ==================================================================== m_grants
do $$
declare f text;
begin
  foreach f in array array[
    'meta_state()', 'meta_state_put(jsonb)', 'meta_queue_add(jsonb)', 'meta_queue_claim(integer)', 'meta_queue_done(bigint, text, text)',
    'meta_ingest(jsonb)', 'meta_relabel(text, boolean)', 'meta_pack_window(text, text, integer, date)', 'meta_pack_series(text, text, integer, date)',
    'meta_pack_new_set(text, text, date)', 'meta_pack_bans(text, date)', 'meta_pack_matchups(text, date)', 'meta_pack_base(text, date)',
    'meta_cluster_input(text, integer)', 'meta_archetype_propose(text, text, text, text, jsonb, text[], integer)',
    'insight_brief_get(text)', 'insight_brief_put(text, text, text, text)',
    'insight_pack_publish(text, text, text, integer, text, text, integer, text, date)', 'insight_pack_current(text, text)',
    'limited_candidates()', 'limited_run_open(text, text, text, text, timestamptz, bigint)', 'limited_run_state(bigint)',
    'limited_step_commit(bigint, integer, bigint, text, text, jsonb, integer, jsonb, boolean)', 'limited_run_fail(bigint, text)',
    'limited_pack_facts(text)', 'limited_kick()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array[
    'insights_index()', 'meta_archetype(text, integer, text, integer)', 'meta_card(text, uuid, text)', 'insights_review()',
    'insights_review_archetype(integer, text, text, text)', 'insights_review_change(integer, text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- ==================================================================== n_cron
create or replace function t1_private.meta_tick()
returns void language sql security definer set search_path = '' as $$
  select t1_private.insights_post('meta-sync', '{"step":"tick"}'::jsonb);
$$;

-- One build request per enabled format, so each fits one edge request's wall clock (its briefs run in parallel).
create or replace function t1_private.meta_build()
returns void language sql security definer set search_path = '' as $$
  select t1_private.insights_post('meta-sync', jsonb_build_object('step', 'build', 'format', format))
    from t1_private.meta_formats where enabled order by ord;
$$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-meta-tick') then
      perform cron.schedule('t1-meta-tick', '*/5 * * * *', 'select t1_private.meta_tick()');
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-meta-build') then
      perform cron.schedule('t1-meta-build', '17 */6 * * *', 'select t1_private.meta_build()');
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-meta-cluster') then
      perform cron.schedule('t1-meta-cluster', '41 3 * * *', $j$select t1_private.insights_post('meta-sync', '{"step":"cluster"}'::jsonb)$j$);
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-meta-legality') then
      perform cron.schedule('t1-meta-legality', '30 5 * * *', 'select t1_private.meta_legality_propose()');
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-limited-check') then
      perform cron.schedule('t1-limited-check', '7 7 * * *', $j$select t1_private.insights_post('limited-sync', '{"step":"check"}'::jsonb)$j$);
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-limited-tick') then
      perform cron.schedule('t1-limited-tick', '*/2 * * * *', 'select t1_private.limited_dispatch()');
    end if;
  end if;
end $$;

-- ==================================================================== o_seed
-- Starting rules, written from ~6,500 MTGO Challenge decks of Sep–Oct 2026 grouped by card overlap, Pauper's Tron and
-- White Weenie widened after checking 790 paper decks from TopDeck.gg (contract § Archetypes). Rules compile against the catalog on insert; Review shows any with missing names.
insert into t1_private.meta_archetypes (format, name, family, colors, status, rule, priority, source) values
  ('modern', 'Eldrazi Bloodchief Combo', 'combo', 'BG', 'approved', '{"main": ["Basking Broodscale", "Blade of the Bloodchief"]}'::jsonb, 10, 'seed'),
  ('modern', 'Living End', 'combo', 'UBRG', 'approved', '{"main": ["Living End"]}'::jsonb, 10, 'seed'),
  ('modern', 'Goryo''s Vengeance', 'combo', 'WUB', 'approved', '{"main": ["Goryo''s Vengeance"]}'::jsonb, 10, 'seed'),
  ('modern', 'Amulet Titan', 'ramp', 'G', 'approved', '{"main": ["Amulet of Vigor"]}'::jsonb, 10, 'seed'),
  ('modern', 'Neoform', 'combo', 'UG', 'approved', '{"main": ["Neoform"]}'::jsonb, 10, 'seed'),
  ('modern', 'Ruby Storm', 'combo', 'R', 'approved', '{"main": ["Ruby Medallion", "Desperate Ritual"]}'::jsonb, 10, 'seed'),
  ('modern', 'Mono-Blue Belcher', 'combo', 'U', 'approved', '{"main": ["Goblin Charbelcher", "Lotus Bloom"]}'::jsonb, 10, 'seed'),
  ('modern', 'Devoted Druid Combo', 'combo', 'G', 'approved', '{"main": ["Devoted Druid"]}'::jsonb, 10, 'seed'),
  ('modern', 'Hollow One', 'aggro', 'R', 'approved', '{"main": ["Hollow One"]}'::jsonb, 10, 'seed'),
  ('modern', 'Persist', 'combo', 'UB', 'approved', '{"main": ["Persist"]}'::jsonb, 10, 'seed'),
  ('modern', 'Boros Land Destruction', 'control', 'RW', 'approved', '{"main": ["Cleansing Wildfire", "Price of Freedom"]}'::jsonb, 10, 'seed'),
  ('modern', 'Izzet Affinity', 'aggro', 'UR', 'approved', '{"main": ["Mox Opal", "Pinnacle Emissary"]}'::jsonb, 20, 'seed'),
  ('modern', 'Eldrazi Tron', 'ramp', '', 'approved', '{"main": ["Karn, the Great Creator", "Devourer of Destiny"]}'::jsonb, 20, 'seed'),
  ('modern', 'Eldrazi Ramp', 'ramp', 'G', 'approved', '{"main": ["Sowing Mycospawn", "Kozilek''s Command"]}'::jsonb, 30, 'seed'),
  ('modern', 'Domain Zoo', 'aggro', 'RGW', 'approved', '{"main": ["Leyline of the Guildpact", "Scion of Draco"]}'::jsonb, 20, 'seed'),
  ('modern', 'Jeskai Energy', 'aggro', 'WUR', 'approved', '{"main": ["Ocelot Pride", "Guide of Souls", "Ephemerate"]}'::jsonb, 20, 'seed'),
  ('modern', 'Boros Energy', 'aggro', 'RW', 'approved', '{"main": ["Ocelot Pride", "Guide of Souls"]}'::jsonb, 30, 'seed'),
  ('modern', 'Izzet Prowess', 'aggro', 'UR', 'approved', '{"main": ["Cori-Steel Cutter"], "any": [["Lava Dart", "Slickshot Show-Off", "Monastery Swiftspear", "Dragon''s Rage Channeler"]], "not": ["Mox Opal"]}'::jsonb, 30, 'seed'),
  ('modern', 'Izzet Murktide', 'midrange', 'UR', 'approved', '{"main": ["Murktide Regent"], "any": [["Unholy Heat", "Lightning Bolt"]]}'::jsonb, 30, 'seed'),
  ('modern', 'Rakdos Moonshadow', 'aggro', 'BR', 'approved', '{"main": ["Moonshadow"]}'::jsonb, 30, 'seed'),
  ('modern', 'Burn', 'aggro', 'R', 'approved', '{"main": ["Lava Spike"], "any": [["Boltwave", "Skewer the Critics", "Rift Bolt"]]}'::jsonb, 30, 'seed'),
  ('modern', 'Azorius Control', 'control', 'WU', 'approved', '{"main": ["Day''s Undoing", "Narset, Parter of Veils"]}'::jsonb, 40, 'seed'),
  ('modern', 'Esper Blink', 'midrange', 'WUB', 'approved', '{"main": ["Flickerwisp", "Ephemerate"]}'::jsonb, 40, 'seed'),
  ('modern', 'Jeskai Control', 'control', 'WUR', 'approved', '{"main": ["Teferi, Time Raveler", "Galvanic Discharge"], "not": ["Ocelot Pride"]}'::jsonb, 50, 'seed'),
  ('modern', 'Dimir Midrange', 'midrange', 'UB', 'approved', '{"main": ["Psychic Frog", "Counterspell"], "not": ["Goryo''s Vengeance", "Ephemerate"]}'::jsonb, 60, 'seed'),
  ('standard', 'Sultai Reanimator', 'combo', 'UBG', 'approved', '{"main": ["Bringer of the Last Gift"]}'::jsonb, 10, 'seed'),
  ('standard', 'Orzhov Lifegain', 'midrange', 'WB', 'approved', '{"main": ["Amalia Benavides Aguirre", "Case of the Uneaten Feast"]}'::jsonb, 10, 'seed'),
  ('standard', 'Boros Dwarves', 'aggro', 'RW', 'approved', '{"main": ["Dwarven Mauler", "Kíli the Resourceful"]}'::jsonb, 10, 'seed'),
  ('standard', 'Rakdos Lizards', 'aggro', 'BR', 'approved', '{"main": ["Hired Claw", "Iridescent Vinelasher", "Master of Barbs"]}'::jsonb, 10, 'seed'),
  ('standard', 'Azorius Artifacts', 'midrange', 'WU', 'approved', '{"main": ["Simulacrum Synthesizer", "Repurposing Bay"]}'::jsonb, 10, 'seed'),
  ('standard', 'Izzet Elementals', 'midrange', 'UR', 'approved', '{"main": ["Sunderflock", "Hearth Elemental"]}'::jsonb, 20, 'seed'),
  ('standard', 'Izzet Prowess', 'aggro', 'UR', 'approved', '{"main": ["Slickshot Show-Off", "Elusive Otter"]}'::jsonb, 20, 'seed'),
  ('standard', 'Boros Dragons', 'midrange', 'RW', 'approved', '{"main": ["Sarkhan, Dragon Ascendant"], "any": [["Nova Hellkite", "Magmatic Hellkite", "Twinmaw Stormbrood"]]}'::jsonb, 20, 'seed'),
  ('standard', 'Mono-Green Landfall', 'aggro', 'G', 'approved', '{"main": ["Earthbender Ascension", "Icetill Explorer"]}'::jsonb, 20, 'seed'),
  ('standard', 'Jund Sacrifice', 'midrange', 'BRG', 'approved', '{"main": ["Greedy Freebooter", "Biotech Specialist"]}'::jsonb, 20, 'seed'),
  ('standard', 'Dimir Midrange', 'midrange', 'UB', 'approved', '{"main": ["Kaito, Bane of Nightmares", "Floodpits Drowner"]}'::jsonb, 30, 'seed'),
  ('standard', 'Dimir Control', 'control', 'UB', 'approved', '{"main": ["Deceit", "Winternight Stories"]}'::jsonb, 40, 'seed'),
  ('standard', 'Jeskai Control', 'control', 'WUR', 'approved', '{"main": ["Jeskai Revelation", "Inevitable Defeat"]}'::jsonb, 40, 'seed'),
  ('standard', 'Azorius Control', 'control', 'WU', 'approved', '{"main": ["No More Lies"], "any": [["Day of Judgment", "Three Steps Ahead", "Get Lost"]]}'::jsonb, 50, 'seed'),
  ('pioneer', 'Greasefang', 'combo', 'WBG', 'approved', '{"main": ["Greasefang, Okiba Boss"]}'::jsonb, 10, 'seed'),
  ('pioneer', 'Izzet Phoenix', 'midrange', 'UR', 'approved', '{"main": ["Arclight Phoenix"]}'::jsonb, 10, 'seed'),
  ('pioneer', 'Storm the Festival', 'ramp', 'URG', 'approved', '{"main": ["Storm the Festival"]}'::jsonb, 10, 'seed'),
  ('pioneer', 'Lumra Scapeshift', 'ramp', 'UG', 'approved', '{"main": ["Scapeshift", "Lumra, Bellow of the Woods"]}'::jsonb, 10, 'seed'),
  ('pioneer', 'Izzet Vivi', 'combo', 'UR', 'approved', '{"main": ["Vivi Ornitier", "Agatha''s Soul Cauldron"]}'::jsonb, 10, 'seed'),
  ('pioneer', 'Boros Land Destruction', 'control', 'RW', 'approved', '{"main": ["Cleansing Wildfire", "Price of Freedom"]}'::jsonb, 10, 'seed'),
  ('pioneer', 'Izzet Lessons', 'midrange', 'UR', 'approved', '{"main": ["Gran-Gran", "Firebending Lesson"]}'::jsonb, 10, 'seed'),
  ('pioneer', 'Mono-White Humans', 'aggro', 'W', 'approved', '{"main": ["Thalia''s Lieutenant", "Kytheon, Hero of Akros"]}'::jsonb, 10, 'seed'),
  ('pioneer', 'Rakdos Sacrifice', 'midrange', 'BR', 'approved', '{"main": ["Witch''s Oven", "Cauldron Familiar"]}'::jsonb, 20, 'seed'),
  ('pioneer', 'Izzet Elementals', 'midrange', 'UR', 'approved', '{"main": ["Sunderflock", "Hearth Elemental"]}'::jsonb, 20, 'seed'),
  ('pioneer', 'Izzet Prowess', 'aggro', 'UR', 'approved', '{"main": ["Emberheart Challenger", "Boomerang Basics"]}'::jsonb, 20, 'seed'),
  ('pioneer', 'Selesnya Company', 'midrange', 'GW', 'approved', '{"main": ["Ouroboroid"], "any": [["Collected Company", "Skyclave Apparition"]]}'::jsonb, 20, 'seed'),
  ('pioneer', 'Golgari Midrange', 'midrange', 'BG', 'approved', '{"main": ["Professor Dellian Fel", "Abrupt Decay"]}'::jsonb, 30, 'seed'),
  ('pioneer', 'Dimir Midrange', 'midrange', 'UB', 'approved', '{"main": ["Kaito, Bane of Nightmares", "Floodpits Drowner"]}'::jsonb, 30, 'seed'),
  ('pioneer', 'Jund Sacrifice', 'midrange', 'BRG', 'approved', '{"main": ["Greedy Freebooter", "Biotech Specialist"]}'::jsonb, 30, 'seed'),
  ('pioneer', 'Mono-Red Aggro', 'aggro', 'R', 'approved', '{"main": ["Kumano Faces Kakkazan", "Soul-Scar Mage"]}'::jsonb, 40, 'seed'),
  ('pioneer', 'Azorius Control', 'control', 'WU', 'approved', '{"main": ["Teferi, Hero of Dominaria"], "any": [["Supreme Verdict", "Temporary Lockdown"]]}'::jsonb, 40, 'seed'),
  ('pauper', 'Bogles', 'aggro', 'GW', 'approved', '{"main": ["Slippery Bogle"]}'::jsonb, 10, 'seed'),
  ('pauper', 'Walls Combo', 'combo', 'BG', 'approved', '{"main": ["Balustrade Spy"]}'::jsonb, 10, 'seed'),
  ('pauper', 'Gruul Storm', 'combo', 'RG', 'approved', '{"main": ["Desperate Ritual", "Seething Song"]}'::jsonb, 10, 'seed'),
  ('pauper', 'Turbo Fog', 'control', 'UG', 'approved', '{"main": ["Moment''s Peace"]}'::jsonb, 10, 'seed'),
  ('pauper', 'Ponza', 'ramp', 'RG', 'approved', '{"main": ["Arbor Elf"], "any": [["Thermokarst", "Mwonvuli Acid-Moss"]]}'::jsonb, 10, 'seed'),
  ('pauper', 'Tron', 'ramp', 'UG', 'approved', '{"main": ["Urza''s Tower", "Urza''s Mine", "Urza''s Power Plant"]}'::jsonb, 20, 'seed'),
  ('pauper', 'Jund Wildfire', 'midrange', 'BRG', 'approved', '{"main": ["Cleansing Wildfire", "Writhing Chrysalis"]}'::jsonb, 20, 'seed'),
  ('pauper', 'Gruul Eldrazi', 'midrange', 'RG', 'approved', '{"main": ["Eldrazi Repurposer", "Avenging Hunter"]}'::jsonb, 30, 'seed'),
  ('pauper', 'Golgari Sacrifice', 'midrange', 'BG', 'approved', '{"main": ["Fanatical Offering", "Tithing Blade"]}'::jsonb, 20, 'seed'),
  ('pauper', 'Affinity', 'aggro', 'UB', 'approved', '{"main": ["Thoughtcast"], "any": [["Myr Enforcer", "Utrom Monitor", "Refurbished Familiar"]]}'::jsonb, 20, 'seed'),
  ('pauper', 'Gruul Goblins', 'aggro', 'RG', 'approved', '{"main": ["Goblin Bushwhacker", "Goblin Tomb Raider"]}'::jsonb, 20, 'seed'),
  ('pauper', 'Mono-Green Elves', 'aggro', 'G', 'approved', '{"main": ["Priest of Titania", "Timberwatch Elf"]}'::jsonb, 20, 'seed'),
  ('pauper', 'White Weenie', 'aggro', 'W', 'approved', '{"main": ["Thraben Inspector"], "any": [["Battle Screech", "Search Party Captain", "Salt Road Packbeast"]], "not": ["Thoughtcast"]}'::jsonb, 25, 'seed'),
  ('pauper', 'Ephemerate Flicker', 'control', 'WU', 'approved', '{"main": ["Ephemerate", "Archaeomancer"]}'::jsonb, 20, 'seed'),
  ('pauper', 'Dimir Faeries', 'midrange', 'UB', 'approved', '{"main": ["Spellstutter Sprite"], "any": [["Cast Down", "Snuff Out"]]}'::jsonb, 30, 'seed'),
  ('pauper', 'Mono-Blue Faeries', 'midrange', 'U', 'approved', '{"main": ["Spellstutter Sprite", "Moon-Circuit Hacker"]}'::jsonb, 40, 'seed'),
  ('pauper', 'Madness Burn', 'aggro', 'R', 'approved', '{"main": ["Fiery Temper", "Faithless Looting"], "any": [["Guttersnipe", "Highway Robbery", "Grab the Prize"]]}'::jsonb, 30, 'seed'),
  ('pauper', 'Mono-Blue Terror', 'midrange', 'U', 'approved', '{"main": ["Tolarian Terror"], "any": [["Mental Note", "Thought Scour"]]}'::jsonb, 40, 'seed'),
  ('pauper', 'Dimir Control', 'control', 'UB', 'approved', '{"main": ["Baleful Strix", "Counterspell"], "not": ["Spellstutter Sprite"]}'::jsonb, 50, 'seed')
on conflict (format, name) do nothing;

-- Banned and restricted changes in the last 12 months, from Wizards' announcements.
insert into t1_private.meta_format_changes (format, on_date, kind, cards, url, status) values
  ('standard', '2025-11-10', 'ban', array['Vivi Ornitier', 'Screaming Nemesis', 'Proft''s Eidetic Memory'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-november-10-2025', 'confirmed'),
  ('pioneer', '2025-11-10', 'ban', array['Heartfire Hero'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-november-10-2025', 'confirmed'),
  ('pauper', '2025-11-10', 'ban', array['High Tide'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-november-10-2025', 'confirmed'),
  ('legacy', '2025-11-10', 'ban', array['Entomb', 'Nadu, Winged Wisdom'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-november-10-2025', 'confirmed'),
  ('pioneer', '2026-05-18', 'ban', array['Cori-Steel Cutter'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-may-18-2026', 'confirmed'),
  ('modern', '2026-05-18', 'ban', array['Phlage, Titan of Fire''s Fury', 'Lotus Field'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-may-18-2026', 'confirmed'),
  ('modern', '2026-05-18', 'unban', array['Violent Outburst', 'Umezawa''s Jitte'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-may-18-2026', 'confirmed'),
  ('legacy', '2026-05-18', 'ban', array['Undercity Informer'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-may-18-2026', 'confirmed'),
  ('pauper', '2026-05-18', 'unban', array['Bonder''s Ornament'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-may-18-2026', 'confirmed'),
  ('legacy', '2026-06-29', 'ban', array['Candelabra of Tawnos'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-june-29-2026', 'confirmed'),
  ('pauper', '2026-06-29', 'ban', array['Seeker of Skybreak'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-june-29-2026', 'confirmed'),
  ('standard', '2026-08-10', 'ban', array['Badgermole Cub', 'Stormchaser''s Talent', 'Gran-Gran'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-august-10-2026', 'confirmed'),
  ('legacy', '2026-08-10', 'ban', array['The Fantasticar'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-august-10-2026', 'confirmed'),
  ('vintage', '2026-08-10', 'restrict', array['The Fantasticar'], 'https://magic.wizards.com/en/news/announcements/banned-and-restricted-august-10-2026', 'confirmed')
on conflict do nothing;
