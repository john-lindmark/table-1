-- Deck finder jobs and Table 1's own results (contract/deck-finder-2026-10-15.md § Jobs, § Table 1 results).
-- A search used to be one long HTTP request from the phone, which iOS drops as soon as the phone is locked.
-- Now a search is a job row: deck_finder_start takes the day's allowance, queues it and posts to the deck-finder
-- function through pg_net (the function claims the job, answers at once and works on in the background); the
-- function finishes the job with deck_finder_finish, which queues one `deck.found` push to the player. The
-- t1-deck-finder-sweep cron job re-sends a job the function never picked up (a refused boot) and fails one that
-- ran too long, so no search waits for ever. The agent reads Table 1's own results (MTGO, Melee, TopDeck;
-- hourly) through deck_finder_events / deck_finder_deck, so a list from yesterday is found before the web has it.

create table if not exists t1_private.deck_finder_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  query text not null,
  format text,
  answers jsonb not null default '[]'::jsonb,
  status text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed')),
  result jsonb,
  -- What the agent is doing, in order, for the screen to show while it runs ("Checking Table 1's results: Modern").
  steps jsonb not null default '[]'::jsonb,
  attempts integer not null default 0,
  request_id bigint,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);
create index if not exists deck_finder_jobs_user_idx on t1_private.deck_finder_jobs (user_id, created_at desc);
create index if not exists deck_finder_jobs_open_idx on t1_private.deck_finder_jobs (created_at) where status in ('queued', 'running');

-- Posts the job to the deck-finder function (x-t1-secret, like notify_kick). The function answers in well under
-- a second (202, then works in the background), so a short timeout is enough.
create or replace function t1_private.deck_finder_kick(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text; v_req bigint;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  v_req := net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/deck-finder',
    body := jsonb_build_object('job_id', p_id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 20000);
  update t1_private.deck_finder_jobs set request_id = v_req, attempts = attempts + 1 where id = p_id;
exception when others then
  raise warning 'deck_finder_kick skipped: %', sqlerrm;
end $$;

-- The job as the clients read it.
create or replace function t1_private.deck_finder_job_json(j t1_private.deck_finder_jobs)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'job_id', j.id, 'status', j.status, 'query', j.query, 'format', j.format, 'answers', j.answers,
    'result', j.result, 'steps', j.steps, 'created_at', j.created_at, 'finished_at', j.finished_at);
$$;

-- Starts a search. Returns {job_id, status}. Raises when the day's allowance is used (the same words the function
-- answered with), when the request is too short, or signed out. The same search already under way (a second tap,
-- a retried call) hands back that job and spends nothing.
create or replace function public.deck_finder_start(p_query text, p_format text default null, p_answers jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_query text; v_format text; v_answers jsonb; v_id uuid;
  v_limit constant integer := 20;
begin
  if v_uid is null then raise exception 'Sign in to find decks' using errcode = '42501'; end if;
  v_query := left(btrim(coalesce(p_query, '')), 500);
  if length(v_query) < 3 then raise exception 'Describe the deck you''re looking for' using errcode = '22023'; end if;
  v_format := lower(btrim(coalesce(p_format, '')));
  if v_format not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'commander', 'premodern', 'canlander') then
    v_format := null;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('question', left(btrim(a->>'question'), 300), 'answer', left(btrim(a->>'answer'), 300)) order by n), '[]'::jsonb)
    into v_answers
    from (select a, n from jsonb_array_elements(case when jsonb_typeof(p_answers) = 'array' then p_answers else '[]'::jsonb end) with ordinality t(a, n)
           where btrim(coalesce(a->>'question', '')) <> '' and btrim(coalesce(a->>'answer', '')) <> ''
           order by n limit 5) s;
  select id into v_id from t1_private.deck_finder_jobs
   where user_id = v_uid and status in ('queued', 'running') and query = v_query
     and format is not distinct from v_format and answers = v_answers and created_at > now() - interval '5 minutes'
   order by created_at desc limit 1;
  if v_id is not null then return jsonb_build_object('job_id', v_id, 'status', 'queued', 'again', true); end if;
  if not public.deck_finder_take(v_uid, v_limit) then
    raise exception 'That''s today''s % searches. Try again tomorrow.', v_limit using errcode = 'P0001';
  end if;
  insert into t1_private.deck_finder_jobs (user_id, query, format, answers) values (v_uid, v_query, v_format, v_answers)
  returning id into v_id;
  perform t1_private.deck_finder_kick(v_id);
  return jsonb_build_object('job_id', v_id, 'status', 'queued');
end $$;

-- One of your jobs (null when it isn't yours or doesn't exist); with no id, your newest job of the last 24 hours,
-- so the Find a deck screen picks up where a locked phone left off.
create or replace function public.deck_finder_job(p_id uuid default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select t1_private.deck_finder_job_json(j)
    from t1_private.deck_finder_jobs j
   where j.user_id = auth.uid()
     and ((p_id is not null and j.id = p_id) or (p_id is null and j.created_at > now() - interval '24 hours'))
   order by j.created_at desc
   limit 1;
$$;

-- The function takes a queued job (null when it's gone or already taken, so two kicks never run it twice).
create or replace function public.deck_finder_claim(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare j t1_private.deck_finder_jobs;
begin
  update t1_private.deck_finder_jobs set status = 'running', started_at = now()
   where id = p_id and status = 'queued'
  returning * into j;
  if j.id is null then return null; end if;
  return jsonb_build_object('job_id', j.id, 'user_id', j.user_id, 'query', j.query, 'format', j.format, 'answers', j.answers);
end $$;

-- The agent's steps so far (the whole list each time; 40 at most, 200 characters each), while the job runs.
create or replace function public.deck_finder_progress(p_id uuid, p_steps jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_steps jsonb;
begin
  select coalesce(jsonb_agg(left(s, 200) order by n), '[]'::jsonb) into v_steps
    from (select s, n from jsonb_array_elements_text(case when jsonb_typeof(p_steps) = 'array' then p_steps else '[]'::jsonb end) with ordinality t(s, n)
           where btrim(s) <> '' order by n limit 40) q;
  update t1_private.deck_finder_jobs set steps = v_steps where id = p_id and status = 'running';
  return found;
end $$;

-- What the push carries: enough for the alert text and the screen it opens, never the whole list.
create or replace function t1_private.deck_finder_push_data(p_id uuid, p_result jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'job_id', p_id, 'status', coalesce(p_result->>'status', 'error'),
    'name', nullif(p_result->'deck'->>'name', ''), 'placement', nullif(p_result->'deck'->>'placement', ''),
    'event', nullif(p_result->'deck'->>'event', ''), 'date', nullif(p_result->'deck'->>'date', ''),
    'question', nullif(p_result->>'question', ''), 'message', nullif(p_result->>'message', '')));
$$;

-- The function's answer (deck / question / not_found / error) ends the job and tells the player. A job already
-- finished (the sweep failed it first) keeps its first result.
create or replace function public.deck_finder_finish(p_id uuid, p_result jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_uid uuid; v_status text;
begin
  v_status := case when coalesce(p_result->>'status', 'error') = 'error' then 'failed' else 'done' end;
  update t1_private.deck_finder_jobs
     set status = v_status, result = coalesce(p_result, '{}'::jsonb), finished_at = now()
   where id = p_id and status in ('queued', 'running')
  returning user_id into v_uid;
  if v_uid is null then return false; end if;
  perform public.enqueue_notification('deck.found', null, array[v_uid], t1_private.deck_finder_push_data(p_id, p_result));
  return true;
end $$;

-- Every minute: a job the function never claimed is sent again (a refused boot; three tries), one that ran too
-- long is failed, and old jobs are forgotten.
create or replace function t1_private.deck_finder_sweep()
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
  v_timeout constant jsonb := jsonb_build_object('status', 'error', 'message', 'The deck finder couldn''t finish that search. Try again.');
begin
  for r in select id, attempts from t1_private.deck_finder_jobs
            where status = 'queued' and created_at < now() - interval '45 seconds' and attempts < 3 loop
    perform t1_private.deck_finder_kick(r.id);
  end loop;
  for r in select id from t1_private.deck_finder_jobs
            where (status = 'queued' and created_at < now() - interval '45 seconds' and attempts >= 3)
               or (status = 'running' and started_at < now() - interval '4 minutes') loop
    perform public.deck_finder_finish(r.id, v_timeout);
  end loop;
  delete from t1_private.deck_finder_jobs where created_at < now() - interval '7 days';
end $$;

-- ---------------------------------------------------------------- Table 1's own results, for the agent

-- Recent events of a format with their best-placed decks (an archetype name narrows both), newest first.
create or replace function public.deck_finder_events(p_format text, p_days integer default 30, p_archetype text default null, p_limit integer default 12)
returns jsonb language sql stable security definer set search_path = '' as $$
  with ev as (
    select e.id, e.name, e.on_date, e.source, e.players, e.tier, e.url
      from t1_private.meta_events e
     where e.format = lower(coalesce(p_format, ''))
       and e.on_date >= current_date - greatest(1, least(coalesce(p_days, 30), 365))
       and exists (select 1 from t1_private.meta_decks d
                     left join t1_private.meta_archetypes a on a.id = d.archetype_id
                    where d.event_id = e.id
                      and (nullif(btrim(coalesce(p_archetype, '')), '') is null or a.name ilike '%' || btrim(p_archetype) || '%'))
     order by e.on_date desc, (e.tier = 'major') desc, coalesce(e.players, 0) desc
     limit greatest(1, least(coalesce(p_limit, 12), 30)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'event_id', ev.id, 'name', ev.name, 'date', ev.on_date, 'source', ev.source, 'players', ev.players, 'tier', ev.tier, 'url', ev.url,
      'decks', (select coalesce(jsonb_agg(jsonb_build_object(
                  'deck_id', d.id, 'archetype', coalesce(a.name, case when d.archetype_id = 0 then 'Other' end), 'colors', d.colors,
                  'rank', d.rank, 'wins', d.wins, 'losses', d.losses, 'draws', d.draws, 'top8', d.top8)
                  order by d.rank nulls last, d.wins desc nulls last, d.id), '[]'::jsonb)
                  from (select d.* from t1_private.meta_decks d
                          left join t1_private.meta_archetypes a on a.id = d.archetype_id
                         where d.event_id = ev.id
                           and (nullif(btrim(coalesce(p_archetype, '')), '') is null or a.name ilike '%' || btrim(p_archetype) || '%')
                         order by d.rank nulls last, d.wins desc nulls last, d.id
                         limit 16) d
                  left join t1_private.meta_archetypes a on a.id = d.archetype_id))
    order by ev.on_date desc, (ev.tier = 'major') desc, coalesce(ev.players, 0) desc), '[]'::jsonb)
  from ev;
$$;

-- One deck as it was published: every card and count, with the event it was played at.
create or replace function public.deck_finder_deck(p_deck_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
      'deck_id', d.id, 'format', d.format, 'date', d.on_date, 'archetype', a.name, 'colors', d.colors,
      'rank', d.rank, 'wins', d.wins, 'losses', d.losses, 'draws', d.draws, 'top8', d.top8,
      'event', e.name, 'url', e.url, 'source', e.source, 'players', e.players,
      'main', (select coalesce(jsonb_agg(jsonb_build_object('qty', u.q, 'name', o.name) order by u.n), '[]'::jsonb)
                 from unnest(d.main, d.main_qty) with ordinality u(id, q, n)
                 join public.card_oracles o on o.oracle_id = u.id),
      'side', (select coalesce(jsonb_agg(jsonb_build_object('qty', u.q, 'name', o.name) order by u.n), '[]'::jsonb)
                 from unnest(d.side, d.side_qty) with ordinality u(id, q, n)
                 join public.card_oracles o on o.oracle_id = u.id))
    from t1_private.meta_decks d
    join t1_private.meta_events e on e.id = d.event_id
    left join t1_private.meta_archetypes a on a.id = d.archetype_id
   where d.id = p_deck_id;
$$;

-- ---------------------------------------------------------------- grants and the sweep

revoke all on function public.deck_finder_start(text, text, jsonb) from public, anon;
grant execute on function public.deck_finder_start(text, text, jsonb) to authenticated, service_role;
revoke all on function public.deck_finder_job(uuid) from public, anon;
grant execute on function public.deck_finder_job(uuid) to authenticated, service_role;
revoke all on function public.deck_finder_claim(uuid) from public, anon, authenticated;
grant execute on function public.deck_finder_claim(uuid) to service_role;
revoke all on function public.deck_finder_finish(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.deck_finder_finish(uuid, jsonb) to service_role;
revoke all on function public.deck_finder_progress(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.deck_finder_progress(uuid, jsonb) to service_role;
revoke all on function public.deck_finder_events(text, integer, text, integer) from public, anon, authenticated;
grant execute on function public.deck_finder_events(text, integer, text, integer) to service_role;
revoke all on function public.deck_finder_deck(bigint) from public, anon, authenticated;
grant execute on function public.deck_finder_deck(bigint) to service_role;
revoke all on function t1_private.deck_finder_kick(uuid) from public, anon, authenticated;
revoke all on function t1_private.deck_finder_sweep() from public, anon, authenticated;
revoke all on function t1_private.deck_finder_job_json(t1_private.deck_finder_jobs) from public, anon, authenticated;
revoke all on function t1_private.deck_finder_push_data(uuid, jsonb) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-deck-finder-sweep') then
      perform cron.schedule('t1-deck-finder-sweep', '* * * * *',
        $c$select t1_private.deck_finder_sweep() where exists (select 1 from t1_private.deck_finder_jobs)$c$);
    end if;
  end if;
end $$;
