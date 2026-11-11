-- "Add your deck photo" push (contract/event-night-2026-10-16.md § 7 "Once your last match is in"): ten minutes
-- after a signed-in player's last match is in, or after the event is finished, one push says so, unless a photo of
-- their deck is up by then. One per player per event, never in demo events, never to guests (no account).
--
-- The rule is the apps' (testdata/deck-photos/prompt.json, from make_prompt.py): t1_private.deck_photo_why_of takes
-- the cases' own shape, so the SQL test runs the same cases, and t1_private.deck_photo_why builds that shape from the
-- tables. A dropped player isn't nudged for the drop (they chose to leave); they are when the event is finished.
--
-- Triggers only queue (t1_private.deck_photo_nudges, due in ten minutes); t1-deck-photo-nudge (every minute) asks the
-- rule again when it's due, so a result undone, a round re-paired, a cancelled event, a top 8 player whose
-- quarterfinal was paired a moment after the round, or a photo added meanwhile sends nothing. A row no longer done is
-- deleted, so the player can be queued again later; a row that sent (or found a photo) stays, so nothing repeats.
-- The triggers run inside pairing, reporting and finishing: an error in them is a warning, never a failed write.

-- ================================================================= the rule (the cases' shape)
create or replace function t1_private.deck_photo_why_of(p_event jsonb, p_me jsonb, p_rounds jsonb)
returns text language sql immutable set search_path = '' as $$
  with rounds as (
    select (r->>'number')::int as n, coalesce(nullif(r->>'stage', ''), 'swiss') as stage, r->'mine' as m
      from jsonb_array_elements(coalesce(p_rounds, '[]'::jsonb)) r
  ), last as (
    select * from rounds where jsonb_typeof(m) = 'object' order by n desc limit 1
  )
  select case
    when p_me is null or jsonb_typeof(p_me) <> 'object' or p_event->>'status' = 'cancelled' then null
    when p_event->>'status' in ('completed', 'archived') then 'over'
    when p_me->>'status' = 'dropped' or p_me->>'dropped_in_round' is not null then 'dropped'
    else (select case
      when not (coalesce((l.m->>'bye')::boolean, false) or l.m->>'status' in ('reported', 'confirmed')) then null
      when l.stage <> 'swiss' then
        case when l.stage = 'final' or (l.m->>'my')::int < (l.m->>'their')::int then 'last' end
      when l.n < coalesce((p_event->>'rounds')::int, 0) then null
      when coalesce((p_event->>'top_cut')::int, 0) = 0 then 'last'
      when exists (select 1 from rounds where stage <> 'swiss') then 'last'
    end from last l)
  end
$$;

-- ================================================================= the rule, from the tables
create or replace function t1_private.deck_photo_why(p_participant_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select t1_private.deck_photo_why_of(
    jsonb_build_object('status', e.status, 'rounds', e.number_of_rounds, 'top_cut', e.top_cut),
    jsonb_build_object('status', p.status, 'dropped_in_round', p.dropped_in_round),
    coalesce((
      select jsonb_agg(jsonb_build_object('number', r.number, 'stage', r.stage, 'mine', (
        select jsonb_build_object('bye', m.is_bye, 'status', m.status, 'my', s.game_wins,
                 'their', coalesce((select o.game_wins from public.match_sides o
                                     where o.match_id = m.id and o.side <> s.side limit 1), 0))
          from public.matches m join public.match_sides s on s.match_id = m.id
         where m.round_id = r.id and s.participant_id = p.id
         limit 1)))
        from public.rounds r where r.event_id = e.id), '[]'::jsonb))
    from public.participants p join public.events e on e.id = p.event_id
   where p.id = p_participant_id
$$;

-- ================================================================= the queue
create table if not exists t1_private.deck_photo_nudges (
  participant_id uuid primary key references public.participants (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null,
  why text not null check (why in ('last', 'over')),
  due_at timestamptz not null,
  sent_at timestamptz,
  outcome text check (outcome in ('sent', 'photo'))
);
alter table t1_private.deck_photo_nudges enable row level security;
create index if not exists deck_photo_nudges_due_idx on t1_private.deck_photo_nudges (due_at) where sent_at is null;
create index if not exists deck_photo_nudges_event_idx on t1_private.deck_photo_nudges (event_id);

create or replace function t1_private.deck_photo_has(p_participant_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.event_deck_photos ph where ph.participant_id = p_participant_id)
$$;

-- Queue one player when they're done ('last' or 'over'), have an account, no photo yet and no row already.
create or replace function t1_private.deck_photo_consider(p_participant_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  p public.participants;
  v_demo boolean;
  v_why text;
begin
  if p_participant_id is null
     or exists (select 1 from t1_private.deck_photo_nudges n where n.participant_id = p_participant_id) then return; end if;
  select * into p from public.participants where id = p_participant_id;
  if p.id is null or p.user_id is null then return; end if;
  select e.is_demo into v_demo from public.events e where e.id = p.event_id;
  if coalesce(v_demo, true) then return; end if;
  v_why := t1_private.deck_photo_why(p.id);
  if v_why is null or v_why not in ('last', 'over') or t1_private.deck_photo_has(p.id) then return; end if;
  insert into t1_private.deck_photo_nudges (participant_id, event_id, user_id, why, due_at)
  values (p.id, p.event_id, p.user_id, v_why, now() + interval '10 minutes')
  on conflict do nothing;
end $$;

create or replace function t1_private.deck_photo_consider_event(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  for v_id in select p.id from public.participants p
               where p.event_id = p_event_id and p.user_id is not null
                 and not exists (select 1 from t1_private.deck_photo_nudges n where n.participant_id = p.id) loop
    perform t1_private.deck_photo_consider(v_id);
  end loop;
end $$;

-- ================================================================= triggers
-- Sides go in after their match (a separate call from events-engine), byes with their games: the players seated,
-- and everyone in the event when the round is a playoff (the cut was made, with or without them).
create or replace function t1_private.deck_photo_sides_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  for v_id in select distinct a.participant_id from added a where a.participant_id is not null loop
    perform t1_private.deck_photo_consider(v_id);
  end loop;
  for v_id in select distinct m.event_id from added a
                join public.matches m on m.id = a.match_id
                join public.rounds r on r.id = m.round_id
               where r.stage <> 'swiss' loop
    perform t1_private.deck_photo_consider_event(v_id);
  end loop;
  return null;
exception when others then
  raise warning 'deck_photo_sides_trg: %', sqlerrm;   -- a nudge never blocks pairing
  return null;
end $$;

drop trigger if exists match_sides_deck_photo on public.match_sides;
create trigger match_sides_deck_photo after insert on public.match_sides
  referencing new table as added for each statement execute function t1_private.deck_photo_sides_trg();

-- A result in (reported, confirmed or changed): at commit, so the games written beside the status are read.
create or replace function t1_private.deck_photo_match_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if new.status not in ('reported', 'confirmed') then return null; end if;
  for v_id in select s.participant_id from public.match_sides s where s.match_id = new.id and s.participant_id is not null loop
    perform t1_private.deck_photo_consider(v_id);
  end loop;
  return null;
exception when others then
  raise warning 'deck_photo_match_trg: %', sqlerrm;   -- a nudge never blocks a result
  return null;
end $$;

drop trigger if exists matches_deck_photo on public.matches;
create constraint trigger matches_deck_photo after update of status on public.matches
  deferrable initially deferred
  for each row execute function t1_private.deck_photo_match_trg();

-- The event is finished: everyone not yet queued.
create or replace function t1_private.deck_photo_event_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.deck_photo_consider_event(new.id);
  return null;
exception when others then
  raise warning 'deck_photo_event_trg: %', sqlerrm;   -- a nudge never blocks finishing an event
  return null;
end $$;

drop trigger if exists events_deck_photo on public.events;
create trigger events_deck_photo after update of status on public.events
  for each row when (new.status = 'completed' and old.status not in ('completed', 'archived', 'cancelled'))
  execute function t1_private.deck_photo_event_trg();

-- ================================================================= sending
create or replace function t1_private.deck_photo_nudge_send()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  n t1_private.deck_photo_nudges;
  e public.events;
  v_why text;
  v_sent integer := 0;
begin
  for n in select * from t1_private.deck_photo_nudges
            where sent_at is null and due_at <= now()
            order by due_at limit 500
            for update skip locked loop
    v_why := t1_private.deck_photo_why(n.participant_id);
    select * into e from public.events where id = n.event_id;
    if v_why is null or v_why not in ('last', 'over') or e.id is null or e.is_demo
       or not exists (select 1 from public.participants p where p.id = n.participant_id and p.user_id = n.user_id) then
      delete from t1_private.deck_photo_nudges where participant_id = n.participant_id;
      continue;
    end if;
    if t1_private.deck_photo_has(n.participant_id) then
      update t1_private.deck_photo_nudges set sent_at = now(), outcome = 'photo' where participant_id = n.participant_id;
      continue;
    end if;
    perform public.enqueue_notification('event.deck_photo', n.event_id, array[n.user_id],
      jsonb_build_object('event_name', e.name, 'why', v_why));
    update t1_private.deck_photo_nudges set sent_at = now(), outcome = 'sent', why = v_why where participant_id = n.participant_id;
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-deck-photo-nudge') then
      perform cron.schedule('t1-deck-photo-nudge', '* * * * *',
        $c$select t1_private.deck_photo_nudge_send() where exists (select 1 from t1_private.deck_photo_nudges where sent_at is null and due_at <= now())$c$);
    end if;
  end if;
end $$;

revoke all on table t1_private.deck_photo_nudges from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['deck_photo_why_of(jsonb, jsonb, jsonb)', 'deck_photo_why(uuid)', 'deck_photo_has(uuid)',
                           'deck_photo_consider(uuid)', 'deck_photo_consider_event(uuid)', 'deck_photo_sides_trg()',
                           'deck_photo_match_trg()', 'deck_photo_event_trg()', 'deck_photo_nudge_send()'] loop
    execute format('revoke all on function t1_private.%s from public, anon, authenticated', f);
  end loop;
end $$;
