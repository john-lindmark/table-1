-- The card says where the viewer stands (John, 2026-10-29: someone already in shouldn't be offered Sign up, someone
-- not in shouldn't be offered Drop). A Discord message's buttons are the same for everyone, so the public card keeps
-- Sign up only and the bot's personal answers (/event show, the sign-up and drop replies) show the one button that
-- applies: `me` on the card is 'player', 'waitlisted' or null for the Discord user it was drawn for, plus `organizer`.
create or replace function t1_private.discord_event_json(p_event_id uuid, p_user_id uuid default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'event_id', e.id, 'name', e.name, 'format_label', e.format_label, 'format_name', e.format_name,
    'set_name', e.set_name, 'cube_name', e.cube_name, 'status', e.status, 'starts_at', e.starts_at,
    'venue_name', e.venue_name, 'capacity', e.capacity, 'top_cut', e.top_cut, 'auto_rounds', e.auto_rounds,
    'number_of_rounds', e.number_of_rounds, 'current_round', e.current_round, 'short_code', e.short_code,
    'organizer_name', (select pr.display_name from public.profiles pr where pr.id = e.created_by and pr.deleted_at is null),
    'sign_up', case when e.status = 'cancelled' or not t1_private.sign_up_open(e) then 'closed'
                    when e.capacity is not null and t1_private.active_players(e.id) >= e.capacity then 'full'
                    else 'open' end,
    'players', t1_private.active_players(e.id),
    'player_names', coalesce((select jsonb_agg(p.display_name order by p.seat nulls last, p.created_at)
                                from public.participants p where p.event_id = e.id and p.status = 'active'), '[]'::jsonb),
    'waitlist', (select count(*) from public.event_waitlist w where w.event_id = e.id),
    'waitlist_names', coalesce((select jsonb_agg(w.display_name order by w.created_at, w.user_id)
                                  from public.event_waitlist w where w.event_id = e.id), '[]'::jsonb),
    'link', 'https://table-1.site/s/' || e.id::text,
    'me', case when p_user_id is null then null
               when exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = p_user_id and p.status = 'active') then 'player'
               when exists (select 1 from public.event_waitlist w where w.event_id = e.id and w.user_id = p_user_id) then 'waitlisted'
               end,
    'organizer', p_user_id is not null and exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = p_user_id),
    'guild_id', d.guild_id, 'channel_id', d.channel_id, 'message_id', d.message_id,
    'results_message_id', d.results_message_id)
    from public.events e left join t1_private.discord_events d on d.event_id = e.id
   where e.id = p_event_id;
$$;
drop function if exists t1_private.discord_event_json(uuid);
revoke execute on function t1_private.discord_event_json(uuid, uuid) from public;

-- The card for a viewer: `me` filled in when the Discord user is linked (an unlinked viewer gets the card with me null).
create or replace function public.discord_event_card(p_guild_id text, p_event_id uuid, p_discord_id text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform t1_private.discord_event_in_guild(p_guild_id, p_event_id);
  return t1_private.discord_event_json(p_event_id, case when p_discord_id is null then null else t1_private.discord_user(p_discord_id) end);
end $$;
drop function if exists public.discord_event_card(text, uuid);
revoke execute on function public.discord_event_card(text, uuid, text) from public, anon, authenticated;
grant execute on function public.discord_event_card(text, uuid, text) to service_role;

-- The acting functions return the card for the person who acted.
create or replace function public.discord_event_create(p_discord_id text, p_guild_id text, p_channel_id text,
  p_format_name text, p_name text default null, p_starts_at timestamptz default null, p_venue_name text default null,
  p_capacity integer default null, p_top_cut integer default 0, p_rounds integer default null,
  p_set_code text default null, p_cube_name text default null, p_local_date date default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  v_res json;
  v_id uuid;
begin
  if p_format_name is null or p_format_name not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper',
      'premodern', 'canadian_highlander', 'other_constructed', 'draft', 'sealed') then
    raise exception 'Pick a format' using errcode = '22023';
  end if;
  if p_rounds is not null and p_rounds not between 1 and 15 then
    raise exception 'Rounds must be 1 to 15' using errcode = '22023';
  end if;
  v_res := public.create_event_v2(p_name => p_name, p_format_name => p_format_name,
    p_rounds => coalesce(p_rounds, 3), p_set_code => nullif(trim(p_set_code), ''),
    p_cube_name => nullif(trim(p_cube_name), ''), p_include_me => true, p_show_clock => true,
    p_local_date => coalesce(p_local_date, (coalesce(p_starts_at, now()) at time zone 'utc')::date),
    p_starts_at => p_starts_at, p_venue_name => p_venue_name, p_capacity => p_capacity,
    p_top_cut => coalesce(p_top_cut, 0), p_auto_rounds => p_rounds is null);
  v_id := (v_res->>'event_id')::uuid;
  insert into t1_private.discord_events (event_id, guild_id, channel_id, created_by)
  values (v_id, p_guild_id, p_channel_id, v_uid);
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (v_id, v_uid, 'discord.posted', 'event', v_id, jsonb_build_object('via', 'create'));
  return t1_private.discord_event_json(v_id, v_uid);
end $$;

create or replace function public.discord_event_attach(p_discord_id text, p_guild_id text, p_channel_id text, p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  e public.events;
  v_access text;
begin
  select * into e from public.events where id = p_event_id;
  v_access := case when e.id is null then 'none' else t1_private.event_access(p_event_id) end;
  if v_access <> 'organizer' and not (v_access = 'player' and e.visibility <> 'private' and not e.is_demo) then
    raise exception 'Only the event''s organizer or players can post it (a private event: its organizer)' using errcode = '42501';
  end if;
  if e.status in ('cancelled', 'archived') then
    raise exception 'That event is over' using errcode = '22023';
  end if;
  insert into t1_private.discord_events (event_id, guild_id, channel_id, created_by)
  values (p_event_id, p_guild_id, p_channel_id, v_uid)
  on conflict (event_id) do update
    set guild_id = excluded.guild_id, channel_id = excluded.channel_id, message_id = null, results_message_id = null,
        created_by = excluded.created_by, updated_at = now();
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, v_uid, 'discord.posted', 'event', p_event_id, jsonb_build_object('via', 'attach', 'as', v_access));
  return t1_private.discord_event_json(p_event_id, v_uid);
end $$;

create or replace function public.discord_event_sign_up(p_discord_id text, p_guild_id text, p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  r jsonb;
begin
  perform t1_private.discord_event_in_guild(p_guild_id, p_event_id);
  r := public.event_sign_up(p_event_id);
  return jsonb_build_object('result', r->>'status', 'position', r->'position') || t1_private.discord_event_json(p_event_id, v_uid);
end $$;

create or replace function public.discord_event_drop(p_discord_id text, p_guild_id text, p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  r jsonb;
begin
  perform t1_private.discord_event_in_guild(p_guild_id, p_event_id);
  r := public.event_leave(p_event_id);
  return jsonb_build_object('result', r->>'status') || t1_private.discord_event_json(p_event_id, v_uid);
end $$;

create or replace function public.discord_event_results(p_discord_id text, p_guild_id text, p_event_id uuid, p_channel_id text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  e public.events;
  v_access text;
  v_org boolean;
  v_final boolean;
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null then raise exception 'That event isn''t available' using errcode = '42501'; end if;
  if not exists (select 1 from t1_private.discord_events d where d.event_id = p_event_id and d.guild_id = p_guild_id) then
    v_access := t1_private.event_access(p_event_id);
    if p_channel_id is null
       or (v_access <> 'organizer' and not (v_access = 'player' and e.visibility <> 'private' and not e.is_demo)) then
      raise exception 'That event isn''t in this server' using errcode = '42501';
    end if;
    insert into t1_private.discord_events (event_id, guild_id, channel_id, created_by)
    values (p_event_id, p_guild_id, p_channel_id, v_uid)
    on conflict (event_id) do update
      set guild_id = excluded.guild_id, channel_id = excluded.channel_id, message_id = null, results_message_id = null,
          created_by = excluded.created_by, updated_at = now();
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
    values (p_event_id, v_uid, 'discord.posted', 'event', p_event_id, jsonb_build_object('via', 'results', 'as', v_access));
  end if;
  if e.status = 'cancelled' then raise exception 'That event was cancelled' using errcode = '22023'; end if;
  v_org := public.is_event_organizer(p_event_id);
  v_final := e.status in ('completed', 'archived');
  if not v_final then
    if not exists (select 1 from public.rounds r where r.event_id = p_event_id) then
      raise exception 'Nothing to post yet: round 1 hasn''t been paired' using errcode = '55000';
    end if;
    if not v_org then
      raise exception 'Only the organizer can post standings before the event ends' using errcode = '42501';
    end if;
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, v_uid, 'discord.results', 'event', p_event_id, jsonb_build_object('final', v_final));
  return jsonb_build_object('final', v_final, 'organizer', v_org) || t1_private.discord_event_json(p_event_id, v_uid);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'discord_event_create(text, text, text, text, text, timestamptz, text, integer, integer, integer, text, text, date)',
    'discord_event_attach(text, text, text, uuid)', 'discord_event_sign_up(text, text, uuid)',
    'discord_event_drop(text, text, uuid)', 'discord_event_results(text, text, uuid, text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
