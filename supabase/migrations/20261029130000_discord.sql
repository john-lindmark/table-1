-- Table 1 for Discord (contract/discord-2026-10-29.md, plan table-1-context/docs/plan-discord-2026-10-29.md).
-- The bot (edge function discord-bot) calls the functions in c_bot as the service role; each one resolves the Discord
-- user to a Table 1 account, acts as that account (the same RPCs the apps call, with their checks, limits and audit
-- rows) and returns the finished card in one round trip. Nothing here is readable or callable by clients except the
-- three web functions in d_web.
--   a_tables   t1_private.discord_links / discord_link_tokens / discord_guilds / discord_events
--   b_helpers  discord_user, discord_act (acts as the account), discord_rate, discord_event_json (the card)
--   c_bot      service-role functions: identity, events, settings, decks, cards
--   d_web      discord_link_confirm, discord_link_status, discord_unlink_me (signed in)
--   e_grants

-- ==================================================================== a_tables
-- One Discord user is one account and one account is one Discord user. Nothing else about Discord is kept: no
-- usernames, no guild names.
create table if not exists t1_private.discord_links (
  discord_user_id text primary key check (discord_user_id ~ '^[0-9]{5,25}$'),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  linked_at timestamptz not null default now()
);
revoke all on t1_private.discord_links from public;

-- /link tokens: sha256 of the token the person was shown, 10 minutes, one per Discord user.
create table if not exists t1_private.discord_link_tokens (
  token_hash text primary key,
  discord_user_id text not null check (discord_user_id ~ '^[0-9]{5,25}$'),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists discord_link_tokens_user_idx on t1_private.discord_link_tokens (discord_user_id);
revoke all on t1_private.discord_link_tokens from public;

-- Per-server settings: the zone /event create reads times in.
create table if not exists t1_private.discord_guilds (
  guild_id text primary key check (guild_id ~ '^[0-9]{5,25}$'),
  timezone text not null default 'UTC',
  updated_at timestamptz not null default now()
);
revoke all on t1_private.discord_guilds from public;

-- Events posted in a server: where the card is, so the bot can edit it, and which server may act on the event.
create table if not exists t1_private.discord_events (
  event_id uuid primary key references public.events(id) on delete cascade,
  guild_id text not null check (guild_id ~ '^[0-9]{5,25}$'),
  channel_id text not null check (channel_id ~ '^[0-9]{5,25}$'),
  message_id text check (message_id is null or message_id ~ '^[0-9]{5,25}$'),
  results_message_id text check (results_message_id is null or results_message_id ~ '^[0-9]{5,25}$'),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists discord_events_guild_idx on t1_private.discord_events (guild_id);
revoke all on t1_private.discord_events from public;

-- ==================================================================== b_helpers
-- The account behind a Discord user: the explicit link first, then a Discord sign-in identity (Supabase's provider
-- keeps the Discord user id as provider_id). Null = not linked.
create or replace function t1_private.discord_user(p_discord_id text)
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select l.user_id from t1_private.discord_links l where l.discord_user_id = p_discord_id),
    (select i.user_id from auth.identities i
      where i.provider = 'discord' and i.provider_id = p_discord_id
      order by i.created_at limit 1))
   where exists (select 1 from public.profiles pr
                  where pr.id = coalesce(
                    (select l.user_id from t1_private.discord_links l where l.discord_user_id = p_discord_id),
                    (select i.user_id from auth.identities i
                      where i.provider = 'discord' and i.provider_id = p_discord_id order by i.created_at limit 1))
                    and pr.deleted_at is null);
$$;

-- How the account is linked: 'link' (/link), 'sign_in' (a Discord identity) or null.
create or replace function t1_private.discord_via(p_user_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when exists (select 1 from t1_private.discord_links l where l.user_id = p_user_id) then 'link'
    when exists (select 1 from auth.identities i where i.user_id = p_user_id and i.provider = 'discord') then 'sign_in'
  end;
$$;

-- Act as the linked account for the rest of this transaction: auth.uid() and auth.role() read these claims, so the
-- public RPCs called next run with that account's rights, limits and audit rows. Service role callers only.
create or replace function t1_private.discord_act(p_discord_id text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_user(p_discord_id);
begin
  if v_uid is null then
    raise exception 'Link your Table 1 account first' using errcode = '28000';
  end if;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  return v_uid;
end $$;

-- A fixed-window limit keyed by Discord user, for calls made before anyone is linked.
create or replace function t1_private.discord_rate(p_discord_id text, p_action text, p_max integer, p_window interval)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_key text := 'd:' || p_discord_id;
begin
  delete from t1_private.rate_hits where key = v_key and action = p_action and at < now() - p_window;
  if (select count(*) from t1_private.rate_hits where key = v_key and action = p_action) >= p_max then
    raise exception 'Too many tries, wait a few minutes' using errcode = '53400';
  end if;
  insert into t1_private.rate_hits (key, action) values (v_key, p_action);
end $$;

-- The card: what the Discord embed shows. Players are the event's active players by seat, with the display names the
-- event already shows every player. No account ids.
create or replace function t1_private.discord_event_json(p_event_id uuid)
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
    'guild_id', d.guild_id, 'channel_id', d.channel_id, 'message_id', d.message_id,
    'results_message_id', d.results_message_id)
    from public.events e left join t1_private.discord_events d on d.event_id = e.id
   where e.id = p_event_id;
$$;

-- The event must have been posted in this server (so a server can only act on its own events).
create or replace function t1_private.discord_event_in_guild(p_guild_id text, p_event_id uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from t1_private.discord_events d where d.event_id = p_event_id and d.guild_id = p_guild_id) then
    raise exception 'That event isn''t in this server' using errcode = '42501';
  end if;
end $$;

-- ==================================================================== c_bot (service role only)
create or replace function public.discord_me(p_discord_id text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when u.id is null then jsonb_build_object('linked', false, 'via', null)
         else jsonb_build_object('linked', true, 'user_id', u.id, 'via', t1_private.discord_via(u.id),
                'display_name', (select pr.display_name from public.profiles pr where pr.id = u.id)) end
    from (select t1_private.discord_user(p_discord_id) id) u;
$$;

-- /link: a one-time token (24 random bytes, base64url; sha256 at rest), 10 minutes, one live token per Discord user.
create or replace function public.discord_link_start(p_discord_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_user(p_discord_id);
  v_token text;
  v_exp timestamptz := now() + interval '10 minutes';
begin
  if v_uid is not null then
    return jsonb_build_object('linked', true,
      'display_name', (select pr.display_name from public.profiles pr where pr.id = v_uid));
  end if;
  if p_discord_id !~ '^[0-9]{5,25}$' then raise exception 'Bad Discord id' using errcode = '22023'; end if;
  perform t1_private.discord_rate(p_discord_id, 'discord.link_start', 5, interval '10 minutes');
  delete from t1_private.discord_link_tokens where discord_user_id = p_discord_id or expires_at < now();
  v_token := translate(rtrim(encode(extensions.gen_random_bytes(24), 'base64'), '='), '+/', '-_');
  insert into t1_private.discord_link_tokens (token_hash, discord_user_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), p_discord_id, v_exp);
  return jsonb_build_object('linked', false, 'token', v_token, 'expires_at', v_exp);
end $$;

-- Removes an explicit link. A Discord sign-in identity is the account's sign-in, not a link: left alone.
create or replace function t1_private.discord_unlink_user(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_via text := t1_private.discord_via(p_user_id);
  v_n integer;
begin
  delete from t1_private.discord_links where user_id = p_user_id;
  get diagnostics v_n = row_count;
  if v_n > 0 then perform t1_private.account_audit(p_user_id, 'discord.unlinked', null, jsonb_build_object('via', 'link'), null); end if;
  return jsonb_build_object('unlinked', v_n > 0, 'via', v_via);
end $$;

create or replace function public.discord_unlink(p_discord_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_user(p_discord_id);
begin
  if v_uid is null then return jsonb_build_object('unlinked', false, 'via', null); end if;
  return t1_private.discord_unlink_user(v_uid);
end $$;

-- /event create: a real Table 1 event made as the linked account (the organizer is seated; rounds follow the player
-- count when p_rounds is null), posted in this channel.
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
  return t1_private.discord_event_json(v_id);
end $$;

-- /event post <link>: the card for an event made in the app. Organizers only; a card already elsewhere moves here.
create or replace function public.discord_event_attach(p_discord_id text, p_guild_id text, p_channel_id text, p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null or not public.is_event_organizer(p_event_id) then
    raise exception 'Only the event''s organizer can post it' using errcode = '42501';
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
  values (p_event_id, v_uid, 'discord.posted', 'event', p_event_id, jsonb_build_object('via', 'attach'));
  return t1_private.discord_event_json(p_event_id);
end $$;

-- Where the card (or the results post) ended up, so later actions can edit it.
create or replace function public.discord_event_posted(p_event_id uuid, p_kind text, p_message_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_kind not in ('event', 'results') then raise exception 'Bad kind' using errcode = '22023'; end if;
  if p_kind = 'event' then
    update t1_private.discord_events set message_id = p_message_id, updated_at = now() where event_id = p_event_id;
  else
    update t1_private.discord_events set results_message_id = p_message_id, updated_at = now() where event_id = p_event_id;
  end if;
  return jsonb_build_object('ok', found);
end $$;

create or replace function public.discord_event_card(p_guild_id text, p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform t1_private.discord_event_in_guild(p_guild_id, p_event_id);
  return t1_private.discord_event_json(p_event_id);
end $$;

-- The server's events for autocomplete and /event list: open ones, or those finished in the last 60 days.
create or replace function public.discord_events_list(p_guild_id text, p_state text default 'open',
  p_query text default null, p_limit integer default 25)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', x.id, 'name', x.name, 'format_label', x.format_label, 'status', x.status,
           'starts_at', x.starts_at, 'players', x.players, 'capacity', x.capacity)
         order by x.starts_at asc nulls last, x.created_at desc), '[]'::jsonb)
    from (
      select e.id, e.name, e.format_label, e.status, e.starts_at, e.capacity, e.created_at,
             t1_private.active_players(e.id) players
        from t1_private.discord_events d join public.events e on e.id = d.event_id
       where d.guild_id = p_guild_id
         and case when coalesce(p_state, 'open') = 'done'
                  then e.status in ('completed', 'archived') and e.updated_at > now() - interval '60 days'
                  else e.status in ('setup', 'seated', 'in_progress') end
         and (nullif(trim(coalesce(p_query, '')), '') is null
              or e.name ilike '%' || replace(replace(trim(p_query), '%', ''), '_', '') || '%')
       order by e.starts_at asc nulls last, e.created_at desc
       limit least(greatest(coalesce(p_limit, 25), 1), 25)) x;
$$;

create or replace function public.discord_event_sign_up(p_discord_id text, p_guild_id text, p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  r jsonb;
begin
  perform t1_private.discord_event_in_guild(p_guild_id, p_event_id);
  r := public.event_sign_up(p_event_id);
  return jsonb_build_object('result', r->>'status', 'position', r->'position') || t1_private.discord_event_json(p_event_id);
end $$;

create or replace function public.discord_event_drop(p_discord_id text, p_guild_id text, p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  r jsonb;
begin
  perform t1_private.discord_event_in_guild(p_guild_id, p_event_id);
  r := public.event_leave(p_event_id);
  return jsonb_build_object('result', r->>'status') || t1_private.discord_event_json(p_event_id);
end $$;

-- /event results: anyone linked once the event is over (the standings page is public anyway); organizers may post
-- "standings so far" after round 1. The function computes the standings with the engine's rules from the rows.
create or replace function public.discord_event_results(p_discord_id text, p_guild_id text, p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  e public.events;
  v_org boolean;
  v_final boolean;
begin
  perform t1_private.discord_event_in_guild(p_guild_id, p_event_id);
  select * into e from public.events where id = p_event_id;
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
  return jsonb_build_object('final', v_final, 'organizer', v_org) || t1_private.discord_event_json(p_event_id);
end $$;

-- /settings timezone: set (a zone Postgres knows) or read (null) the server's zone.
create or replace function public.discord_guild_timezone(p_guild_id text, p_timezone text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_tz text;
begin
  if p_timezone is not null then
    begin
      perform now() at time zone p_timezone;
    exception when others then
      raise exception 'Unknown time zone: use a name like Europe/Stockholm or America/New_York' using errcode = '22023';
    end;
    if p_timezone ~ '^[+-]?[0-9]' then
      raise exception 'Unknown time zone: use a name like Europe/Stockholm or America/New_York' using errcode = '22023';
    end if;
    insert into t1_private.discord_guilds (guild_id, timezone) values (p_guild_id, p_timezone)
    on conflict (guild_id) do update set timezone = excluded.timezone, updated_at = now();
  end if;
  select g.timezone into v_tz from t1_private.discord_guilds g where g.guild_id = p_guild_id;
  return jsonb_build_object('guild_id', p_guild_id, 'timezone', coalesce(v_tz, 'UTC'), 'set', v_tz is not null);
end $$;

-- /deck autocomplete: the account's own decks.
create or replace function public.discord_my_decks(p_discord_id text, p_query text default null, p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('list_id', x.id, 'name', x.name, 'format', x.format, 'cards', x.cards,
                                        'shared', x.shared) order by x.updated_at desc)
      from (
        select l.id, l.name, l.format, l.updated_at,
               (select coalesce(sum(en.qty), 0) from public.card_list_entries en where en.list_id = l.id and en.board <> 'maybe') cards,
               exists (select 1 from public.share_links k where k.user_id = v_uid and k.part = 'deck' and k.item_id = l.id
                          and k.revoked_at is null) shared
          from public.card_lists l
         where l.user_id = v_uid and l.kind = 'deck' and l.deleted_at is null
           and (nullif(trim(coalesce(p_query, '')), '') is null
                or l.name ilike '%' || replace(replace(trim(p_query), '%', ''), '_', '') || '%')
         order by l.updated_at desc
         limit least(greatest(coalesce(p_limit, 25), 1), 25)) x), '[]'::jsonb);
end $$;

-- /deck: a deck post is a share link ("Anyone with the link", revocable from Sharing). No live link and no
-- confirmation yet → ask first. Spice and the hero card come along when they exist.
create or replace function public.discord_deck_share(p_discord_id text, p_list_id uuid, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  l public.card_lists;
  k public.share_links;
  v_token text;
  v_new boolean := false;
  v_spice jsonb;
  v_hero jsonb;
  v_hero_oracle uuid;
begin
  select * into l from public.card_lists where id = p_list_id and user_id = v_uid and kind = 'deck' and deleted_at is null;
  if l.id is null then raise exception 'That isn''t your deck' using errcode = '42501'; end if;
  select * into k from public.share_links
   where user_id = v_uid and part = 'deck' and item_id = l.id and revoked_at is null;
  if k.id is null and not coalesce(p_confirm, false) then
    return jsonb_build_object('needs_confirm', true, 'list_id', l.id, 'name', l.name, 'format', l.format);
  end if;
  if k.id is null then
    v_token := public.share_link_create('deck', l.id)->>'token';
    v_new := true;
  else
    v_token := k.token;
  end if;
  begin
    v_spice := public.list_spice(l.id);
  exception when others then
    v_spice := null;
  end;
  select h.oracle_ids[1] into v_hero_oracle from public.library_heroes h
   where h.user_id = v_uid and h.scope = 'list' and h.target_id = l.id;
  select jsonb_build_object('card_id', c.id, 'image_ts', c.image_ts, 'name', o.name) into v_hero
    from public.card_list_entries en join public.cards c on c.id = en.card_id
    join public.card_oracles o on o.oracle_id = c.oracle_id
   where en.list_id = l.id and en.board in ('main', 'commander') and c.image_ts is not null
   order by (c.oracle_id = v_hero_oracle) desc, (en.board = 'commander') desc, en.qty desc, o.name
   limit 1;
  return jsonb_build_object(
    'needs_confirm', false, 'list_id', l.id, 'name', l.name, 'format', l.format,
    'main', (select coalesce(sum(en.qty), 0) from public.card_list_entries en where en.list_id = l.id and en.board in ('main', 'commander')),
    'side', (select coalesce(sum(en.qty), 0) from public.card_list_entries en where en.list_id = l.id and en.board = 'side'),
    'spice', case when v_spice ? 'score' and v_spice->>'score' is not null
                  then jsonb_build_object('score', v_spice->'score', 'word', v_spice->'word') end,
    'url', 'https://table-1.site/l/' || v_token, 'new_link', v_new, 'hero', v_hero);
end $$;

-- /card: the catalog's best match with its cheapest near-mint TCGplayer prices and an image.
create or replace function public.discord_card(p_query text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s record;
begin
  if char_length(trim(coalesce(p_query, ''))) < 2 then return null; end if;
  select * into s from public.search_cards(trim(p_query), 1);
  if s.oracle_id is null then return null; end if;
  return (
    select jsonb_build_object(
      'oracle_id', s.oracle_id, 'name', s.name, 'mana_cost', s.mana_cost, 'type_line', s.type_line,
      'card_id', s.default_card_id, 'image_ts', s.image_ts,
      'set_code', c.set_code, 'collector_number', c.collector_number,
      'usd', (select min(p.usd) from public.cards x join public.card_prices p on p.card_id = x.id where x.oracle_id = s.oracle_id),
      'usd_foil', (select min(p.usd_foil) from public.cards x join public.card_prices p on p.card_id = x.id where x.oracle_id = s.oracle_id),
      'printings', (select count(*) from public.cards x where x.oracle_id = s.oracle_id and x.lang = 'en'))
      from (select 1) one left join public.cards c on c.id = s.default_card_id);
end $$;

-- ==================================================================== d_web (signed in)
-- The page behind the /link URL: links the signed-in account to the token's Discord user.
create or replace function public.discord_link_confirm(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  t t1_private.discord_link_tokens;
  v_other uuid;
  v_had integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  perform t1_private.rate_hit('discord.link', 10, 30, interval '10 minutes');
  delete from t1_private.discord_link_tokens where expires_at < now();
  if nullif(trim(coalesce(p_token, '')), '') is not null then
    delete from t1_private.discord_link_tokens
     where token_hash = encode(extensions.digest(trim(p_token), 'sha256'), 'hex') returning * into t;
  end if;
  if t.discord_user_id is null then
    raise exception 'That link has expired. Run /link again in Discord' using errcode = '22023';
  end if;
  v_other := t1_private.discord_user(t.discord_user_id);
  if v_other is not null and v_other <> v_uid then
    raise exception 'That Discord account is already linked to another Table 1 account' using errcode = '23505';
  end if;
  delete from t1_private.discord_links where user_id = v_uid and discord_user_id <> t.discord_user_id;
  get diagnostics v_had = row_count;
  if v_had > 0 then perform t1_private.account_audit(v_uid, 'discord.unlinked', null, jsonb_build_object('via', 'link'), null); end if;
  insert into t1_private.discord_links (discord_user_id, user_id) values (t.discord_user_id, v_uid)
  on conflict (discord_user_id) do update set linked_at = now();
  perform t1_private.account_audit(v_uid, 'discord.linked', null, null, jsonb_build_object('via', 'link'));
  return jsonb_build_object('linked', true,
    'linked_at', (select l.linked_at from t1_private.discord_links l where l.user_id = v_uid));
end $$;

create or replace function public.discord_link_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_via text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  v_via := t1_private.discord_via(v_uid);
  return jsonb_build_object('linked', v_via is not null, 'via', v_via,
    'linked_at', case v_via
      when 'link' then (select l.linked_at from t1_private.discord_links l where l.user_id = v_uid)
      when 'sign_in' then (select min(i.created_at) from auth.identities i where i.user_id = v_uid and i.provider = 'discord') end);
end $$;

create or replace function public.discord_unlink_me()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return t1_private.discord_unlink_user(v_uid);
end $$;

-- ==================================================================== e_grants
do $$
declare f text;
begin
  foreach f in array array[
    'discord_me(text)', 'discord_link_start(text)', 'discord_unlink(text)',
    'discord_event_create(text, text, text, text, text, timestamptz, text, integer, integer, integer, text, text, date)',
    'discord_event_attach(text, text, text, uuid)', 'discord_event_posted(uuid, text, text)',
    'discord_event_card(text, uuid)', 'discord_events_list(text, text, text, integer)',
    'discord_event_sign_up(text, text, uuid)', 'discord_event_drop(text, text, uuid)',
    'discord_event_results(text, text, uuid)', 'discord_guild_timezone(text, text)',
    'discord_my_decks(text, text, integer)', 'discord_deck_share(text, uuid, boolean)', 'discord_card(text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['discord_link_confirm(text)', 'discord_link_status()', 'discord_unlink_me()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
revoke execute on function t1_private.discord_user(text), t1_private.discord_via(uuid), t1_private.discord_act(text),
  t1_private.discord_rate(text, text, integer, interval), t1_private.discord_event_json(uuid),
  t1_private.discord_event_in_guild(text, uuid), t1_private.discord_unlink_user(uuid) from public;
