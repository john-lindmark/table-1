-- Organizer tools for the room (contract/room-tools-2026-11-13.md; plan § Phase 4): what every display shows and an
-- announcement, extra time for a table, and a judge call from a player's screen.
--
-- Every write pings `event:<id>` like the other event tables, so displays, trackers and the organizer follow at once.

-- ==================================================================== a_display
create table if not exists public.event_displays (
  event_id uuid primary key references public.events (id) on delete cascade,
  show text not null default 'auto' check (show in ('auto', 'clock', 'pairings', 'standings')),
  message text check (message is null or char_length(message) between 1 and 140),
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- The organizer picks what every display of the event shows and pins a line of text. p_patch keys: show, message
-- (null or blank clears).
create or replace function public.event_display_set(p_event_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); d public.event_displays; v_show text; v_msg text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then raise exception 'Only organizers can change the display' using errcode = '42501'; end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'Say what to change' using errcode = '22023'; end if;
  select * into d from public.event_displays where event_id = p_event_id;
  v_show := coalesce(d.show, 'auto'); v_msg := d.message;
  if p_patch ? 'show' then
    v_show := p_patch->>'show';
    if v_show is null or v_show not in ('auto', 'clock', 'pairings', 'standings') then
      raise exception 'Show auto, clock, pairings or standings' using errcode = '22023';
    end if;
  end if;
  if p_patch ? 'message' then
    v_msg := nullif(btrim(regexp_replace(coalesce(p_patch->>'message', ''), '\s+', ' ', 'g')), '');
    if char_length(v_msg) > 140 then raise exception 'Keep the announcement under 140 characters' using errcode = '22023'; end if;
  end if;
  insert into public.event_displays (event_id, show, message, updated_by) values (p_event_id, v_show, v_msg, v_uid)
  on conflict (event_id) do update set show = excluded.show, message = excluded.message, updated_by = v_uid, updated_at = now();
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (p_event_id, v_uid, 'display.set', 'event', p_event_id,
          jsonb_build_object('show', coalesce(d.show, 'auto'), 'message', d.message), jsonb_build_object('show', v_show, 'message', v_msg));
  return jsonb_build_object('show', v_show, 'message', v_msg);
end $$;

-- ==================================================================== b_time
alter table public.matches add column if not exists extra_seconds integer not null default 0;
alter table public.matches drop constraint if exists matches_extra_seconds_check;
alter table public.matches add constraint matches_extra_seconds_check check (extra_seconds between 0 and 3600);

-- Extra time for one table in the round being played (a judge call, a deck check). p_seconds adds to what the table
-- already has (negative takes back); the total stays within 0 to 60 minutes.
create or replace function public.match_time_extend(p_match_id uuid, p_seconds integer, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); m public.matches; r public.rounds; v_new integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into m from public.matches where id = p_match_id for update;
  if m.id is null or not public.is_event_organizer(m.event_id) then
    raise exception 'Only organizers can give extra time' using errcode = '42501';
  end if;
  select * into r from public.rounds where id = m.round_id;
  if r.status <> 'active' then raise exception 'That round is over' using errcode = '22023'; end if;
  if m.is_bye then raise exception 'A bye has no clock' using errcode = '22023'; end if;
  v_new := m.extra_seconds + coalesce(p_seconds, 0);
  if p_seconds is null or p_seconds = 0 or v_new not between 0 and 3600 then
    raise exception 'Extra time is 0 to 60 minutes a table' using errcode = '22023';
  end if;
  update public.matches set extra_seconds = v_new where id = m.id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, reason, before, after)
  values (m.event_id, v_uid, 'match.time_extended', 'match', m.id, nullif(left(btrim(coalesce(p_reason, '')), 200), ''),
          jsonb_build_object('extra_seconds', m.extra_seconds), jsonb_build_object('extra_seconds', v_new));
  return jsonb_build_object('match_id', m.id, 'table_number', m.table_number, 'extra_seconds', v_new);
end $$;

-- ==================================================================== c_judge
create table if not exists public.judge_calls (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  match_id uuid not null references public.matches (id) on delete cascade,
  participant_id uuid references public.participants (id) on delete set null,
  called_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid,
  resolution text check (resolution is null or resolution in ('done', 'cancelled'))
);
create unique index if not exists judge_calls_open_idx on public.judge_calls (match_id) where resolved_at is null;
create index if not exists judge_calls_event_idx on public.judge_calls (event_id) where resolved_at is null;

-- The caller's participant in a match: their account's seat, or the guest seat their claim token opens.
create or replace function t1_private.match_seat(p_match_id uuid, p_token text)
returns uuid language sql stable security definer set search_path = '' as $$
  select s.participant_id
    from public.match_sides s
   where s.match_id = p_match_id and s.participant_id is not null
     and ((auth.uid() is not null and s.user_id = auth.uid())
          or (p_token is not null and exists (select 1 from public.participant_tokens t
                                               where t.participant_id = s.participant_id and t.token = p_token)))
   limit 1;
$$;

-- A player calls a judge to their table (once while a call is open). The organizers get a push.
create or replace function public.judge_call(p_match_id uuid, p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_pid uuid := t1_private.match_seat(p_match_id, p_token);
  m public.matches; r public.rounds; e public.events; c public.judge_calls; v_name text;
begin
  if v_pid is null then raise exception 'Only the players at a table can call a judge to it' using errcode = '42501'; end if;
  perform t1_private.rate_hit('judge.call', 6, 30, interval '10 minutes');
  select * into m from public.matches where id = p_match_id;
  select * into r from public.rounds where id = m.round_id;
  select * into e from public.events where id = m.event_id;
  if r.status <> 'active' or e.status in ('completed', 'archived', 'cancelled') then
    raise exception 'That round is over' using errcode = '22023';
  end if;
  select * into c from public.judge_calls where match_id = p_match_id and resolved_at is null;
  if c.id is null then
    insert into public.judge_calls (event_id, match_id, participant_id) values (m.event_id, m.id, v_pid)
    on conflict do nothing returning * into c;
    if c.id is not null then
      select p.display_name into v_name from public.participants p where p.id = v_pid;
      insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id)
      values (m.event_id, auth.uid(), v_name, 'judge.called', 'match', m.id);
      if not e.is_demo then
        perform public.enqueue_notification('judge.call', m.event_id,
          array(select em.user_id from public.event_members em where em.event_id = m.event_id and em.user_id is distinct from auth.uid()),
          jsonb_build_object('table_number', m.table_number, 'event_name', e.name, 'by', v_name, 'match_id', m.id));
      end if;
    else
      select * into c from public.judge_calls where match_id = p_match_id and resolved_at is null;
    end if;
  end if;
  return jsonb_build_object('call_id', c.id, 'match_id', m.id, 'called_at', c.called_at);
end $$;

-- The table takes its call back.
create or replace function public.judge_call_cancel(p_match_id uuid, p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  if t1_private.match_seat(p_match_id, p_token) is null then
    raise exception 'Only the players at a table can take its call back' using errcode = '42501';
  end if;
  update public.judge_calls set resolved_at = now(), resolved_by = auth.uid(), resolution = 'cancelled'
   where match_id = p_match_id and resolved_at is null;
  get diagnostics v_n = row_count;
  return jsonb_build_object('cancelled', v_n > 0);
end $$;

-- An organizer marks a call handled.
create or replace function public.judge_call_resolve(p_call_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.judge_calls;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into c from public.judge_calls where id = p_call_id;
  if c.id is null or not public.is_event_organizer(c.event_id) then
    raise exception 'Only organizers can close a judge call' using errcode = '42501';
  end if;
  if c.resolved_at is null then
    update public.judge_calls set resolved_at = now(), resolved_by = auth.uid(), resolution = 'done' where id = c.id;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
    values (c.event_id, auth.uid(), 'judge.resolved', 'match', c.match_id);
  end if;
  return jsonb_build_object('call_id', c.id, 'resolved', true);
end $$;

-- ==================================================================== d_room
-- The room's state for whoever can open the event: what displays show, tables with extra time this round, and
-- judge calls (every open one for organizers; a player's own table's call otherwise).
create or replace function public.event_room(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_access text := t1_private.event_access(p_event_id, p_token);
  v_round uuid;
  v_mine uuid;
begin
  if v_access = 'none' then raise exception 'That event isn''t available' using errcode = '42501'; end if;
  select r.id into v_round from public.rounds r where r.event_id = p_event_id order by r.number desc limit 1;
  if v_round is not null then
    select m.id into v_mine from public.matches m
     where m.round_id = v_round and t1_private.match_seat(m.id, p_token) is not null limit 1;
  end if;
  return jsonb_build_object(
    'display', coalesce((select jsonb_build_object('show', d.show, 'message', d.message)
                           from public.event_displays d where d.event_id = p_event_id),
                        jsonb_build_object('show', 'auto', 'message', null)),
    'extensions', coalesce((select jsonb_agg(jsonb_build_object('match_id', m.id, 'table_number', m.table_number,
                                                                 'extra_seconds', m.extra_seconds) order by m.table_number)
                              from public.matches m where m.round_id = v_round and m.extra_seconds > 0), '[]'::jsonb),
    'calls', case when v_access = 'organizer' then coalesce((
               select jsonb_agg(jsonb_build_object('call_id', c.id, 'match_id', c.match_id, 'table_number', m.table_number,
                                                   'called_at', c.called_at,
                                                   'by', (select p.display_name from public.participants p where p.id = c.participant_id))
                                order by c.called_at)
                 from public.judge_calls c join public.matches m on m.id = c.match_id
                where c.event_id = p_event_id and c.resolved_at is null), '[]'::jsonb) end,
    'my_match', case when v_mine is not null then (
               select jsonb_build_object('match_id', m.id, 'table_number', m.table_number, 'extra_seconds', m.extra_seconds,
                                         'call_open', exists (select 1 from public.judge_calls c where c.match_id = m.id and c.resolved_at is null))
                 from public.matches m where m.id = v_mine) end);
end $$;

-- ==================================================================== e_pings, grants
alter table public.event_displays enable row level security;
alter table public.judge_calls enable row level security;
revoke all on public.event_displays, public.judge_calls from anon, authenticated;
do $$
declare t text; f text;
begin
  foreach t in array array['event_displays', 'judge_calls'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_ping_ins', t);
    execute format('drop trigger if exists %I on public.%I', t || '_ping_upd', t);
    execute format('create trigger %I after insert on public.%I referencing new table as new_rows '
                   'for each statement execute function t1_private.event_ping(%L)', t || '_ping_ins', t, 'event_id');
    execute format('create trigger %I after update on public.%I referencing old table as old_rows new table as new_rows '
                   'for each statement execute function t1_private.event_ping(%L)', t || '_ping_upd', t, 'event_id');
  end loop;
  execute 'revoke execute on function t1_private.match_seat(uuid, text) from public, anon, authenticated';
  foreach f in array array['public.event_display_set(uuid, jsonb)', 'public.match_time_extend(uuid, integer, text)',
                           'public.judge_call_resolve(uuid)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- Guests play with a claim token and no account, so these are open to signed-out callers who hold one.
  foreach f in array array['public.judge_call(uuid, text)', 'public.judge_call_cancel(uuid, text)', 'public.event_room(uuid, text)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;
