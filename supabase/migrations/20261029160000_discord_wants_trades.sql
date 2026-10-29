-- Table 1 for Discord: /wants and /trades (contract/discord-2026-10-29.md § Wants and for trade). A post of your wants
-- or of your cards for trade, the whole list or one card, behind the part's "Anyone with the link" share link (made
-- only after you confirm, like /deck). Max prices never leave the database. Service role only, acting as the account.

-- The names behind a part, for autocomplete: your wanted cards, or the cards in your for-trade binders.
create or replace function public.discord_part_names(p_discord_id text, p_part text, p_query text default null, p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  v_q text := nullif(trim(coalesce(p_query, '')), '');
begin
  if p_part not in ('wants', 'for_trade') then raise exception 'Wants or for trade' using errcode = '22023'; end if;
  return coalesce((
    select jsonb_agg(x.name order by (v_q is not null and lower(x.name) like lower(v_q) || '%') desc, x.name)
      from (
        select distinct o.name
          from (select w.oracle_id from public.wants w where w.user_id = v_uid and w.qty > 0 and p_part = 'wants'
                union
                select c.oracle_id from public.binder_items bi
                  join public.binders b on b.id = bi.binder_id
                  join public.cards c on c.id = bi.card_id
                 where bi.user_id = v_uid and bi.qty > 0 and b.for_trade and b.deleted_at is null and p_part = 'for_trade') s
          join public.card_oracles o on o.oracle_id = s.oracle_id
         where v_q is null or o.name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%'
         limit least(greatest(coalesce(p_limit, 25), 1), 25)) x), '[]'::jsonb);
end $$;

-- The post: rows (one card, or every card), the part's live share link (or needs_confirm), counts and value.
--   wants:     {name, qty, set, number, finish, usd (the cheapest near-mint price the want takes), card_id, image_ts}
--   for_trade: {name, qty, set, number, finish, condition, lang, usd (at the copy's condition), card_id, image_ts}
create or replace function public.discord_part(p_discord_id text, p_part text, p_query text default null, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  v_q text := nullif(trim(coalesce(p_query, '')), '');
  k public.share_links;
  v_token text;
  v_new boolean := false;
  v_rows jsonb;
  v_total integer;
  v_cards integer;
  v_value numeric;
begin
  if p_part not in ('wants', 'for_trade') then raise exception 'Wants or for trade' using errcode = '22023'; end if;
  select * into k from public.share_links
   where user_id = v_uid and part = p_part and item_id is null and revoked_at is null;
  if k.id is null and not coalesce(p_confirm, false) then
    return jsonb_build_object('needs_confirm', true, 'part', p_part);
  end if;
  if k.id is null then
    v_token := public.share_link_create(p_part)->>'token';
    v_new := true;
  else
    v_token := k.token;
  end if;

  if p_part = 'wants' then
    with rows as (
      select o.name, w.qty, c.set_code set, c.collector_number number, w.finish, pr.now usd,
             coalesce(w.card_id, pr.now_card_id, (select x.id from public.cards x where x.oracle_id = w.oracle_id and x.lang = 'en' and x.image_ts is not null
                                                     order by x.released_at desc nulls last limit 1)) card_id
        from public.wants w
        join public.card_oracles o on o.oracle_id = w.oracle_id
        left join public.cards c on c.id = w.card_id
        left join t1_private.want_prices_of(v_uid) pr on pr.oracle_id = w.oracle_id
             and pr.card_id is not distinct from w.card_id and pr.finish is not distinct from w.finish
       where w.user_id = v_uid and w.qty > 0
         and (v_q is null or o.name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
    )
    select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'qty', r.qty, 'set', r.set, 'number', r.number, 'finish', r.finish,
                      'usd', r.usd, 'card_id', r.card_id, 'image_ts', (select x.image_ts from public.cards x where x.id = r.card_id))
                    order by r.name, r.set nulls first, r.finish nulls first), '[]'::jsonb),
           count(*)::int, coalesce(sum(r.qty), 0)::int, coalesce(sum(r.usd * r.qty), 0)
      into v_rows, v_total, v_cards, v_value
      from (select * from rows limit 200) r;
  else
    with rows as (
      select o.name, sum(bi.qty)::int qty, c.set_code set, c.collector_number number, bi.finish, bi.condition, bi.lang,
             t1_private.condition_price(case bi.finish when 'foil' then p.usd_foil when 'etched' then p.usd_etched else p.usd end, bi.condition) usd,
             c.id card_id, c.image_ts
        from public.binder_items bi
        join public.binders b on b.id = bi.binder_id
        join public.cards c on c.id = bi.card_id
        join public.card_oracles o on o.oracle_id = c.oracle_id
        left join t1_private.card_prices_usd p on p.card_id = c.id
       where bi.user_id = v_uid and bi.qty > 0 and b.for_trade and b.deleted_at is null
         and (v_q is null or o.name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
       group by o.name, c.id, c.set_code, c.collector_number, c.image_ts, bi.finish, bi.condition, bi.lang, p.usd, p.usd_foil, p.usd_etched
    )
    select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'qty', r.qty, 'set', r.set, 'number', r.number, 'finish', r.finish,
                      'condition', r.condition, 'lang', r.lang, 'usd', r.usd, 'card_id', r.card_id, 'image_ts', r.image_ts)
                    order by r.name, r.set, r.finish, r.condition), '[]'::jsonb),
           count(*)::int, coalesce(sum(r.qty), 0)::int, coalesce(sum(r.usd * r.qty), 0)
      into v_rows, v_total, v_cards, v_value
      from (select * from rows limit 200) r;
  end if;

  return jsonb_build_object(
    'needs_confirm', false, 'part', p_part, 'query', v_q, 'rows', v_rows, 'rows_total', v_total, 'cards', v_cards,
    'value', v_value, 'url', 'https://table-1.site/l/' || v_token, 'token', v_token, 'new_link', v_new,
    'owner', (select pr.display_name from public.profiles pr where pr.id = v_uid));
end $$;

do $$
declare f text;
begin
  foreach f in array array['discord_part_names(text, text, text, integer)', 'discord_part(text, text, text, boolean)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- /event post: the account's own events to pick from (the ones it runs or plays in), open first, then the recent ones.
create or replace function public.discord_my_events(p_discord_id text, p_query text default null, p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  v_q text := nullif(trim(coalesce(p_query, '')), '');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('event_id', x.id, 'name', x.name, 'format_label', x.format_label, 'status', x.status,
                                        'starts_at', x.starts_at, 'role', x.role, 'players', t1_private.active_players(x.id))
                    order by (x.status in ('setup', 'seated', 'in_progress')) desc, x.starts_at asc nulls last, x.created_at desc)
      from (
        select e.id, e.name, e.format_label, e.status, e.starts_at, e.created_at,
               case when exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = v_uid) then 'organizer' else 'player' end role
          from public.events e
         where not e.is_demo and e.status not in ('cancelled', 'archived')
           and (e.status in ('setup', 'seated', 'in_progress') or e.updated_at > now() - interval '60 days')
           and (exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = v_uid)
                or exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = v_uid))
           and (v_q is null or e.name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
         order by (e.status in ('setup', 'seated', 'in_progress')) desc, e.starts_at asc nulls last, e.created_at desc
         limit least(greatest(coalesce(p_limit, 25), 1), 25)) x), '[]'::jsonb);
end $$;
revoke execute on function public.discord_my_events(text, text, integer) from public, anon, authenticated;
grant execute on function public.discord_my_events(text, text, integer) to service_role;

-- discord_event_attach (from 20261029130000_discord): a player may post an event they're in too, as long as it isn't
-- private (its link is open to anyone then); organizers may post any of theirs.
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
  return t1_private.discord_event_json(p_event_id);
end $$;
revoke execute on function public.discord_event_attach(text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.discord_event_attach(text, text, text, uuid) to service_role;
