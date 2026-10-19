-- Privacy lockdown, step 1: additive (plan table-1-context/docs/plan-privacy-lockdown-2026-10-18.md,
-- contract/privacy-lockdown-2026-10-18.md). Every build keeps working.
-- One rule decides who can read an event (t1_private.event_access). New RPCs serve those reads: event_bundle for
-- organizers, players and guests with a token; event_preview / event_public for someone with only the link or code;
-- people for names and avatars. Clients move to them next. The table read policies for events and profiles are
-- tightened in step 3, after the clients have moved.
-- In this step: join_event refuses private events and rate-limits codes (codes resolve only while the event is open),
-- get_event_teams needs access, writes to event tables send a data-free 'changed' ping on 'event:<id>', and
-- lifetime records / head-to-head / results are no longer readable from tables (no client reads them).
-- Blocks don't change event access: blocking can't take someone out of a tournament (John, 2026-10-18).

-- ==================================================================== a_access
-- 'organizer' | 'player' | 'guest' | 'invited' | 'link' | 'none'.
--   organizer  event_members row for the caller
--   player     a participant linked to the caller's account
--   guest      p_token is the claim token of a participant in this event (web guests, signed out)
--   invited    a pending event_invites row for the caller
--   link       anyone else, when the event isn't private, cancelled or demo
create or replace function t1_private.event_access(p_event_id uuid, p_token text default null)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when e.id is null then 'none'
    when exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = auth.uid()) then 'organizer'
    when exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = auth.uid()) then 'player'
    when nullif(p_token, '') is not null and exists (
           select 1 from public.participant_tokens t join public.participants p on p.id = t.participant_id
            where t.token = p_token and p.event_id = e.id) then 'guest'
    when exists (select 1 from public.event_invites i
                  where i.event_id = e.id and i.user_id = auth.uid() and i.status = 'pending') then 'invited'
    when e.visibility <> 'private' and e.status <> 'cancelled' and not e.is_demo then 'link'
    else 'none' end
    from (select 1) one left join public.events e on e.id = p_event_id;
$$;

-- A small fixed-window counter for calls that may come signed out. Keyed by account, else by the client address
-- (PostgREST's request.headers), else one shared 'anon' key.
create table if not exists t1_private.rate_hits (
  key text not null,
  action text not null,
  at timestamptz not null default now()
);
create index if not exists rate_hits_key_idx on t1_private.rate_hits (key, action, at);
revoke all on t1_private.rate_hits from public;

create or replace function t1_private.rate_key()
returns text language sql stable set search_path = '' as $$
  select coalesce('u:' || auth.uid()::text,
                  'ip:' || nullif(trim(split_part(
                    coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1)), ''),
                  'anon');
$$;

-- Counts one hit and refuses (53400) when the caller already has p_max in the window. Signed-in callers get
-- p_max; addresses get p_max_ip (a store's wifi is many players behind one address).
create or replace function t1_private.rate_hit(p_action text, p_max integer, p_max_ip integer, p_window interval)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_key text := t1_private.rate_key();
  v_max integer := case when v_key like 'u:%' then p_max else p_max_ip end;
begin
  delete from t1_private.rate_hits where key = v_key and action = p_action and at < now() - p_window;
  if (select count(*) from t1_private.rate_hits where key = v_key and action = p_action) >= v_max then
    raise exception 'Too many tries, wait a few minutes' using errcode = '53400';
  end if;
  insert into t1_private.rate_hits (key, action) values (v_key, p_action);
end $$;

-- Already over the limit (without counting a hit).
create or replace function t1_private.rate_over(p_action text, p_max integer, p_max_ip integer, p_window interval)
returns boolean language sql stable security definer set search_path = '' as $$
  select count(*) >= case when t1_private.rate_key() like 'u:%' then p_max else p_max_ip end
    from t1_private.rate_hits where key = t1_private.rate_key() and action = p_action and at >= now() - p_window;
$$;

-- An open event by its 4-character code: not finished, cancelled or archived. Misses are counted, so codes
-- can't be worked through (20 misses per 10 minutes per account, 60 per address).
create or replace function t1_private.event_by_code(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if t1_private.rate_over('code.miss', 20, 60, interval '10 minutes') then
    raise exception 'Too many tries, wait a few minutes' using errcode = '53400';
  end if;
  select e.id into v_id from public.events e
   where upper(e.short_code) = upper(trim(coalesce(p_code, '')))
     and e.status not in ('completed', 'archived', 'cancelled');
  if v_id is null then perform t1_private.rate_hit('code.miss', 1000000, 1000000, interval '10 minutes'); end if;
  return v_id;
end $$;

-- ==================================================================== b_reads
create or replace function t1_private.event_teams_json(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'name', t.name, 'order', t.display_order,
           'members', (select coalesce(jsonb_agg(jsonb_build_object(
                          'participant_id', p.id, 'display_name', p.display_name, 'slot', p.team_slot,
                          'user_id', p.user_id, 'status', p.status) order by p.team_slot), '[]'::jsonb)
                         from public.participants p where p.team_id = t.id)
         ) order by t.display_order), '[]'::jsonb)
    from public.event_teams t
   where t.event_id = p_event_id and t.active;
$$;

-- Everything a member sees, in one call: the rows clients read today from events, participants (by seat) and
-- rounds with matches and match_sides (rounds by number, matches by table, sides by side), plus teams.
create or replace function public.event_bundle(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_access text := t1_private.event_access(p_event_id, p_token);
begin
  if v_access not in ('organizer', 'player', 'guest') then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'event', (select to_jsonb(e) from public.events e where e.id = p_event_id),
    'participants', coalesce((select jsonb_agg(to_jsonb(p) order by p.seat nulls last, p.created_at, p.id)
                                from public.participants p where p.event_id = p_event_id), '[]'::jsonb),
    'rounds', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('matches', coalesce((
                  select jsonb_agg(to_jsonb(m) || jsonb_build_object('match_sides', coalesce((
                             select jsonb_agg(to_jsonb(s) order by s.side, s.id) from public.match_sides s where s.match_id = m.id),
                           '[]'::jsonb))
                         order by m.table_number nulls last, m.id)
                    from public.matches m where m.round_id = r.id), '[]'::jsonb))
                order by r.number)
                from public.rounds r where r.event_id = p_event_id), '[]'::jsonb),
    'teams', t1_private.event_teams_json(p_event_id),
    'is_organizer', v_access = 'organizer',
    'access', v_access);
end $$;

-- What someone sees before joining: no player list, no account ids, no coordinates.
create or replace function t1_private.event_preview_json(p_event_id uuid, p_access text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'event_id', e.id, 'access', p_access, 'short_code', e.short_code, 'name', e.name, 'format_label', e.format_label,
    'set_name', e.set_name, 'cube_name', e.cube_name, 'status', e.status, 'starts_at', e.starts_at,
    'venue_name', e.venue_name, 'capacity', e.capacity,
    'players', (select count(*) from public.participants p where p.event_id = e.id and p.status = 'active'),
    'organizer_name', (select pr.display_name from public.profiles pr where pr.id = e.created_by and pr.deleted_at is null))
    from public.events e where e.id = p_event_id;
$$;

-- By code (typed at the table; open events only, rate-limited) or by id (a link). Private events only for their
-- organizers, players and invited accounts. Anything else returns {access: 'none'} and nothing more. It's a result,
-- not an error, so the miss counted against the caller is kept (an error would roll it back).
create or replace function public.event_preview(p_code text default null, p_event_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := p_event_id;
  v_by_code boolean := nullif(trim(coalesce(p_code, '')), '') is not null;
  v_access text;
begin
  if v_by_code then
    perform t1_private.rate_hit('preview.code', 60, 300, interval '10 minutes');
    v_id := t1_private.event_by_code(p_code);
  end if;
  v_access := t1_private.event_access(v_id);
  if v_access = 'none' then
    if v_by_code and v_id is not null then
      perform t1_private.rate_hit('code.miss', 1000000, 1000000, interval '10 minutes');
    end if;
    return jsonb_build_object('event_id', null, 'access', 'none');
  end if;
  return t1_private.event_preview_json(v_id, v_access);
end $$;

-- What the shared standings page (/s/:eventId) shows, for link and above: the event header, the active round's clock
-- and its pairings by display name (no account ids). Standings rows come from events-engine, which calls this first
-- as the caller and so refuses whoever this refuses.
create or replace function public.event_public(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_access text := t1_private.event_access(p_event_id, p_token);
  v_round public.rounds;
begin
  if v_access = 'none' then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  select * into v_round from public.rounds r where r.event_id = p_event_id and r.status = 'active'
   order by r.number desc limit 1;
  return t1_private.event_preview_json(p_event_id, v_access) || (
    select jsonb_build_object(
      'current_round', e.current_round, 'number_of_rounds', e.number_of_rounds, 'show_clock', e.show_clock,
      'format_name', e.format_name, 'team_size', e.team_size,
      'round', case when v_round.id is null then null else jsonb_build_object(
        'id', v_round.id, 'number', v_round.number, 'status', v_round.status,
        'timer_duration_seconds', v_round.timer_duration_seconds,
        'timer_remaining_at_change', v_round.timer_remaining_at_change, 'timer_status', v_round.timer_status,
        'timer_last_started_at', v_round.timer_last_started_at, 'timer_ends_at', v_round.timer_ends_at) end,
      'pairings', case when v_round.id is null then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object(
                 'match_id', m.id, 'table_number', m.table_number, 'is_bye', m.is_bye, 'status', m.status,
                 'game_draws', m.game_draws, 'intentional_draw', m.intentional_draw,
                 'sides', (select coalesce(jsonb_agg(jsonb_build_object(
                              'side', s.side, 'participant_id', s.participant_id, 'display_name', p.display_name,
                              'game_wins', s.game_wins) order by s.side), '[]'::jsonb)
                             from public.match_sides s left join public.participants p on p.id = s.participant_id
                            where s.match_id = m.id))
               order by m.table_number nulls last, m.id)
          from public.matches m where m.round_id = v_round.id), '[]'::jsonb) end)
      from public.events e where e.id = p_event_id);
end $$;

-- Old builds call get_event_teams(p_event_id); guests on the web pass their token.
drop function if exists public.get_event_teams(uuid);
create or replace function public.get_event_teams(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if t1_private.event_access(p_event_id, p_token) not in ('organizer', 'player', 'guest') then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  return t1_private.event_teams_json(p_event_id);
end $$;

-- ==================================================================== c_people
-- Name and avatar for ids the caller has a reason to see: themselves, anyone with a friendship row with them
-- (friends, requests either way), anyone they share an event with (as player or organizer; an invite links the
-- invited account and the event's organizers), and public profiles. Never across a block, either way. Deleted
-- accounts never; demo accounts only through a shared (demo) event. Ids outside the rule are left out quietly,
-- so the answer never says whether an id exists.
create or replace function public.people(p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if coalesce(cardinality(p_ids), 0) > 500 then
    raise exception 'At most 500 people at a time' using errcode = '22023';
  end if;
  return coalesce((
    with ids as (select distinct x id from unnest(coalesce(p_ids, '{}')) x where x is not null),
    mine as (
      select p.event_id from public.participants p where p.user_id = v_uid
      union select m.event_id from public.event_members m where m.user_id = v_uid
    )
    select jsonb_agg(jsonb_build_object('user_id', pr.id, 'display_name', pr.display_name, 'handle', pr.handle,
                                        'avatar_url', pr.avatar_url) order by pr.id)
      from ids join public.profiles pr on pr.id = ids.id
     where pr.deleted_at is null
       and (pr.id = v_uid or (
         not exists (select 1 from public.user_blocks b
                      where (b.user_id = v_uid and b.blocked_id = pr.id) or (b.user_id = pr.id and b.blocked_id = v_uid))
         and (
           exists (select 1 from public.participants p join mine on mine.event_id = p.event_id where p.user_id = pr.id)
           or exists (select 1 from public.event_members m join mine on mine.event_id = m.event_id where m.user_id = pr.id)
           or exists (select 1 from public.event_invites i join public.event_members m on m.event_id = i.event_id
                       where (i.user_id = v_uid and m.user_id = pr.id) or (i.user_id = pr.id and m.user_id = v_uid))
           or (not pr.is_demo and (
                 exists (select 1 from public.friendships f
                          where f.user_lo = least(v_uid, pr.id) and f.user_hi = greatest(v_uid, pr.id))
                 or exists (select 1 from public.share_settings s where s.user_id = pr.id and s.profile = 'public')))
         )))), '[]'::jsonb);
end $$;

-- ==================================================================== d_join
-- join_event (from 20261012120000_cancel_players_demo) plus: private events need an invite (or the QR code, which
-- carries its secret: join_event_qr is unchanged), codes resolve only while the event is open and are rate-limited,
-- and an account already in the event gets its own seat back instead of a second one.
-- A code that doesn't lead to a joinable event returns {error, message} rather than raising, so the miss counted
-- against the caller is kept (error: not_found | cancelled | finished | private).
create or replace function public.join_event(p_code text, p_display_name text)
returns json language plpgsql security definer set search_path = 'public' as $$
declare
  v_event public.events;
  v_pod_id uuid;
  v_participant_id uuid;
  v_token text;
  v_seat int;
  v_refuse text;
begin
  if length(trim(coalesce(p_display_name,''))) = 0 then
    raise exception 'A name is required';
  end if;
  perform t1_private.rate_hit('join.code', 20, 200, interval '10 minutes');
  if t1_private.rate_over('code.miss', 20, 60, interval '10 minutes') then
    raise exception 'Too many tries, wait a few minutes' using errcode = '53400';
  end if;
  select * into v_event from public.events where upper(short_code) = upper(trim(coalesce(p_code, '')));
  v_refuse := case
    when v_event.id is null then 'not_found'
    when v_event.status = 'cancelled' then 'cancelled'
    when v_event.status in ('completed','archived') then 'finished'
    when v_event.visibility = 'private'
         and t1_private.event_access(v_event.id) not in ('organizer', 'player', 'invited') then 'private'
    end;
  if v_refuse is not null then
    perform t1_private.rate_hit('code.miss', 1000000, 1000000, interval '10 minutes');
    return json_build_object('error', v_refuse, 'message', case v_refuse
      when 'cancelled' then 'That event was cancelled'
      when 'finished' then 'That event has already finished'
      when 'private' then 'Ask the organizer for an invite'
      else 'No event found with that code' end);
  end if;

  if auth.uid() is not null then
    select p.id, t.token into v_participant_id, v_token
      from public.participants p left join public.participant_tokens t on t.participant_id = p.id
     where p.event_id = v_event.id and p.user_id = auth.uid()
     order by p.created_at limit 1;
    if v_participant_id is not null then
      if v_token is null then
        insert into public.participant_tokens (participant_id) values (v_participant_id) returning token into v_token;
      end if;
      return json_build_object('event_id', v_event.id, 'short_code', v_event.short_code,
                               'participant_id', v_participant_id, 'token', v_token, 'already_joined', true);
    end if;
  end if;

  select id into v_pod_id from public.pods where event_id = v_event.id order by display_order limit 1;
  select coalesce(max(seat), 0) + 1 into v_seat from public.participants where event_id = v_event.id;

  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (v_event.id, v_pod_id, auth.uid(), trim(p_display_name), v_seat)
  returning id into v_participant_id;

  insert into public.participant_tokens (participant_id) values (v_participant_id)
  returning token into v_token;

  insert into public.audit_log (event_id, actor_label, action, target_type, target_id)
  values (v_event.id, trim(p_display_name), 'participant.joined', 'participant', v_participant_id);

  return json_build_object(
    'event_id', v_event.id,
    'short_code', v_event.short_code,
    'participant_id', v_participant_id,
    'token', v_token
  );
end $$;

-- ==================================================================== e_pings
-- After any write to an event's rows: one 'changed' ping with no data on the public topic 'event:<event id>', once
-- per event per statement. Clients refetch through event_bundle / event_public, so data still passes the access
-- check; this replaces postgres_changes, which needs open table reads to reach guests. Best effort: a failed ping
-- never fails the write (clients also refetch on focus).
create or replace function t1_private.event_ping()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_col text := coalesce(tg_argv[0], 'event_id');
  v_id uuid;
begin
  for v_id in execute format(
      case tg_op when 'INSERT' then 'select distinct %1$I from new_rows where %1$I is not null'
                 when 'DELETE' then 'select distinct %1$I from old_rows where %1$I is not null'
                 else 'select %1$I from new_rows where %1$I is not null union select %1$I from old_rows where %1$I is not null' end,
      v_col) loop
    begin
      perform realtime.send('{}'::jsonb, 'changed', 'event:' || v_id::text, false);
    exception when others then
      raise warning 'event ping failed for %: %', v_id, sqlerrm;
    end;
  end loop;
  return null;
end $$;
revoke execute on function t1_private.event_ping() from public;

do $$
declare
  t text;
  c text;
begin
  foreach t in array array['events', 'participants', 'rounds', 'matches', 'match_sides', 'event_teams'] loop
    c := case t when 'events' then 'id' else 'event_id' end;
    execute format('drop trigger if exists %I on public.%I', t || '_ping_ins', t);
    execute format('drop trigger if exists %I on public.%I', t || '_ping_upd', t);
    execute format('drop trigger if exists %I on public.%I', t || '_ping_del', t);
    execute format('create trigger %I after insert on public.%I referencing new table as new_rows '
                   'for each statement execute function t1_private.event_ping(%L)', t || '_ping_ins', t, c);
    execute format('create trigger %I after update on public.%I referencing old table as old_rows new table as new_rows '
                   'for each statement execute function t1_private.event_ping(%L)', t || '_ping_upd', t, c);
    execute format('create trigger %I after delete on public.%I referencing old table as old_rows '
                   'for each statement execute function t1_private.event_ping(%L)', t || '_ping_del', t, c);
  end loop;
end $$;

-- ==================================================================== f_records
-- Lifetime records, head-to-head, final results and standings snapshots: server-only. Another account's record shows
-- only through profile_view (which applies their Record setting); yours through account_overview. No client reads
-- these tables; security definer functions and the service role are unaffected.
drop policy if exists player_records_read on public.player_records;
drop policy if exists head_to_head_read on public.head_to_head;
drop policy if exists match_outcomes_read on public.match_outcomes;
drop policy if exists event_results_read on public.event_results;
drop policy if exists standings_snapshots_read on public.standings_snapshots;
revoke select on public.player_records, public.head_to_head, public.match_outcomes, public.event_results,
                 public.standings_snapshots from anon, authenticated;

-- ==================================================================== g_grants
do $$
declare f text;
begin
  foreach f in array array[
    'event_access(uuid, text)', 'rate_key()', 'rate_hit(text, integer, integer, interval)',
    'rate_over(text, integer, integer, interval)', 'event_by_code(text)', 'event_teams_json(uuid)',
    'event_preview_json(uuid, text)'] loop
    execute format('revoke execute on function t1_private.%s from public', f);
  end loop;
  -- Signed-out callers too: web guests (with their token) and people opening a shared link.
  foreach f in array array[
    'event_bundle(uuid, text)', 'event_preview(text, uuid)', 'event_public(uuid, text)', 'get_event_teams(uuid, text)',
    'join_event(text, text)'] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
  execute 'revoke execute on function public.people(uuid[]) from public, anon';
  execute 'grant execute on function public.people(uuid[]) to authenticated';
end $$;
