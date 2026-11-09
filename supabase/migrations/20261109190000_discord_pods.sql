-- Discord and drafts with several pods (contract/discord-2026-10-29.md § Pods; contract/draft-pods-2026-11-09.md).
--   the card    discord_event_json carries the pick (pods, pod_pairing) and, once seated, each pod's size
--   /event create  takes pods and pairing for a draft (through set_event_pods, so it's audited like the apps)
--   redraws     a posted card redraws when the pick or anyone's pod changes
-- Re-pairing a round needs nothing here: withdraw_round and the new pairing both change current_round, which
-- already redraws the card, and the bot reads the event as it is when it redraws.

-- discord_event_json (from 20261029190000_discord_card_me) plus pods, pod_pairing and pod_sizes (drafts only;
-- pod_sizes: active seated players per pod in pod order, once the seats are drawn).
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
    'pods', case when e.format_name = 'draft' then e.pods end,
    'pod_pairing', case when e.format_name = 'draft' then e.pod_pairing end,
    'pod_sizes', case when e.format_name = 'draft' and e.status <> 'setup' then coalesce((
                   select jsonb_agg(x.n order by x.display_order) from (
                     select d.display_order, count(p.id) n from public.pods d
                       join public.participants p on p.pod_id = d.id and p.status = 'active' and p.seat is not null
                      where d.event_id = e.id group by d.id, d.display_order) x), '[]'::jsonb) end,
    'guild_id', d.guild_id, 'channel_id', d.channel_id, 'message_id', d.message_id,
    'results_message_id', d.results_message_id)
    from public.events e left join t1_private.discord_events d on d.event_id = e.id
   where e.id = p_event_id;
$$;
revoke execute on function t1_private.discord_event_json(uuid, uuid) from public;

-- discord_event_create (from 20261029190000_discord_card_me) plus p_pods (null = automatic) and p_pod_pairing
-- ('pod' | 'cross', null = inside pods) for a draft; either one on another format is refused before anything is made.
drop function if exists public.discord_event_create(text, text, text, text, text, timestamptz, text, integer, integer,
  integer, text, text, date);
create or replace function public.discord_event_create(p_discord_id text, p_guild_id text, p_channel_id text,
  p_format_name text, p_name text default null, p_starts_at timestamptz default null, p_venue_name text default null,
  p_capacity integer default null, p_top_cut integer default 0, p_rounds integer default null,
  p_set_code text default null, p_cube_name text default null, p_local_date date default null,
  p_pods integer default null, p_pod_pairing text default null)
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
  if (p_pods is not null or p_pod_pairing is not null) and p_format_name <> 'draft' then
    raise exception 'Pods and pairing are for drafts' using errcode = '22023';
  end if;
  if p_pods is not null and p_pods not between 1 and 16 then
    raise exception 'Pods are 1 to 16' using errcode = '22023';
  end if;
  if p_pod_pairing is not null and p_pod_pairing not in ('pod', 'cross') then
    raise exception 'Pair inside pods or across pods' using errcode = '22023';
  end if;
  v_res := public.create_event_v2(p_name => p_name, p_format_name => p_format_name,
    p_rounds => coalesce(p_rounds, 3), p_set_code => nullif(trim(p_set_code), ''),
    p_cube_name => nullif(trim(p_cube_name), ''), p_include_me => true, p_show_clock => true,
    p_local_date => coalesce(p_local_date, (coalesce(p_starts_at, now()) at time zone 'utc')::date),
    p_starts_at => p_starts_at, p_venue_name => p_venue_name, p_capacity => p_capacity,
    p_top_cut => coalesce(p_top_cut, 0), p_auto_rounds => p_rounds is null);
  v_id := (v_res->>'event_id')::uuid;
  if p_pods is not null or p_pod_pairing is not null then
    perform public.set_event_pods(v_id, p_pods, coalesce(p_pod_pairing, 'pod'));
  end if;
  insert into t1_private.discord_events (event_id, guild_id, channel_id, created_by)
  values (v_id, p_guild_id, p_channel_id, v_uid);
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (v_id, v_uid, 'discord.posted', 'event', v_id, jsonb_build_object('via', 'create'));
  return t1_private.discord_event_json(v_id, v_uid);
end $$;
revoke execute on function public.discord_event_create(text, text, text, text, text, timestamptz, text, integer, integer,
  integer, text, text, date, integer, text) from public, anon, authenticated;
grant execute on function public.discord_event_create(text, text, text, text, text, timestamptz, text, integer, integer,
  integer, text, text, date, integer, text) to service_role;

-- Redraws: the pick and a player's pod are on the card now.
drop trigger if exists participants_discord_card on public.participants;
create trigger participants_discord_card
  after insert or delete or update of status, display_name, seat, pod_id on public.participants
  for each row execute function t1_private.discord_card_kick_row();

drop trigger if exists events_discord_card on public.events;
create trigger events_discord_card
  after update on public.events
  for each row when ((old.name, old.status, old.starts_at, old.venue_name, old.capacity, old.top_cut, old.auto_rounds,
                      old.number_of_rounds, old.current_round, old.set_name, old.cube_name, old.pods, old.pod_pairing)
           is distinct from (new.name, new.status, new.starts_at, new.venue_name, new.capacity, new.top_cut, new.auto_rounds,
                             new.number_of_rounds, new.current_round, new.set_name, new.cube_name, new.pods, new.pod_pairing))
  execute function t1_private.discord_card_kick_event();
