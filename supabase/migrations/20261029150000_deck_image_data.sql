-- The deck image on the server (contract/discord-2026-10-29.md § The deck picture): what the deck-image function needs
-- to draw a deck behind a share link, and the Discord bot's deck post gaining the deck's version (for the picture's
-- cache key). Reads only; the link's own checks (share_link_open) decide who may see it.

-- Everything the picture needs, by share link: the deck, its owner's name, and each line with the card's name, type,
-- mana value, set and image. Considering is left out, as on the clients. Any caller with the link (signed out too).
create or replace function public.deck_image_data(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  k public.share_links;
  l public.card_lists;
begin
  k := t1_private.share_link_open(p_token);
  if k.part <> 'deck' then raise exception 'That link isn''t a deck' using errcode = '22023'; end if;
  select * into l from public.card_lists where id = k.item_id;
  if l.id is null or l.deleted_at is not null then raise exception 'This isn''t available' using errcode = '42501'; end if;
  return jsonb_build_object(
    'name', l.name, 'format', l.format, 'version', l.current_version, 'updated_at', l.updated_at,
    'owner', (select pr.display_name from public.profiles pr where pr.id = k.user_id and pr.deleted_at is null),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'card_id', e.card_id, 'oracle_id', c.oracle_id, 'name', o.name, 'board', e.board, 'qty', e.qty,
               'finish', e.finish, 'type_line', o.type_line, 'cmc', o.cmc, 'set', c.set_code, 'image_ts', c.image_ts)
             order by e.board, e.card_id, e.finish)
        from public.card_list_entries e
        join public.cards c on c.id = e.card_id
        join public.card_oracles o on o.oracle_id = c.oracle_id
       where e.list_id = l.id and e.board <> 'maybe'), '[]'::jsonb));
end $$;
grant execute on function public.deck_image_data(text) to anon, authenticated, service_role;

-- discord_deck_share (from 20261029130000_discord) plus the deck's version, so the bot's picture link changes when
-- the deck does.
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
    'needs_confirm', false, 'list_id', l.id, 'name', l.name, 'format', l.format, 'version', l.current_version,
    'main', (select coalesce(sum(en.qty), 0) from public.card_list_entries en where en.list_id = l.id and en.board in ('main', 'commander')),
    'side', (select coalesce(sum(en.qty), 0) from public.card_list_entries en where en.list_id = l.id and en.board = 'side'),
    'spice', case when v_spice ? 'score' and v_spice->>'score' is not null
                  then jsonb_build_object('score', v_spice->'score', 'word', v_spice->'word') end,
    'url', 'https://table-1.site/l/' || v_token, 'token', v_token, 'new_link', v_new, 'hero', v_hero);
end $$;
revoke execute on function public.discord_deck_share(text, uuid, boolean) from public, anon, authenticated;
grant execute on function public.discord_deck_share(text, uuid, boolean) to service_role;
