-- The posted event card follows the event wherever it changes (contract/discord-2026-10-29.md § The card stays
-- current). It used to refresh on bot actions only, so a sign-up from the app, the web or the sign-up link left the
-- Discord card behind. Now any change to an event's players, waitlist or details asks discord-bot (pg_net, after
-- commit, `x-t1-secret`) to redraw the card, once per event per transaction; the bot reads the card then.

-- Asks the bot to redraw one event's card, if the event has one; at most once per event in a transaction.
create or replace function t1_private.discord_card_kick(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_done text := coalesce(current_setting('t1.discord_kicked', true), '');
begin
  if p_event_id is null or position(p_event_id::text in v_done) > 0 then return; end if;
  if not exists (select 1 from t1_private.discord_events d where d.event_id = p_event_id and d.message_id is not null) then
    return;
  end if;
  perform set_config('t1.discord_kicked', v_done || p_event_id::text || ',', true);
  perform t1_private.insights_post('discord-bot', jsonb_build_object('refresh', p_event_id));
end $$;

create or replace function t1_private.discord_card_kick_row() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.discord_card_kick(case when tg_op = 'DELETE' then old.event_id else new.event_id end);
  return null;
end $$;

create or replace function t1_private.discord_card_kick_event() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.discord_card_kick(new.id);
  return null;
end $$;

drop trigger if exists participants_discord_card on public.participants;
create trigger participants_discord_card
  after insert or delete or update of status, display_name, seat on public.participants
  for each row execute function t1_private.discord_card_kick_row();

drop trigger if exists event_waitlist_discord_card on public.event_waitlist;
create trigger event_waitlist_discord_card
  after insert or delete or update of display_name on public.event_waitlist
  for each row execute function t1_private.discord_card_kick_row();

-- Only what the card shows.
drop trigger if exists events_discord_card on public.events;
create trigger events_discord_card
  after update on public.events
  for each row when ((old.name, old.status, old.starts_at, old.venue_name, old.capacity, old.top_cut, old.auto_rounds,
                      old.number_of_rounds, old.current_round, old.set_name, old.cube_name)
           is distinct from (new.name, new.status, new.starts_at, new.venue_name, new.capacity, new.top_cut, new.auto_rounds,
                             new.number_of_rounds, new.current_round, new.set_name, new.cube_name))
  execute function t1_private.discord_card_kick_event();

-- What the bot draws when asked: the card without a viewer, with where it is posted.
create or replace function public.discord_card_current(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select t1_private.discord_event_json(p_event_id, null)
   where exists (select 1 from t1_private.discord_events d where d.event_id = p_event_id and d.message_id is not null);
$$;

-- The card's message is gone (deleted, or the channel is): stop asking, unless it was posted again since.
create or replace function public.discord_card_lost(p_event_id uuid, p_message_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  update t1_private.discord_events set message_id = null, updated_at = now()
   where event_id = p_event_id and message_id = p_message_id;
  return jsonb_build_object('ok', found);
end $$;

revoke all on function t1_private.discord_card_kick(uuid) from public;
revoke all on function t1_private.discord_card_kick_row() from public;
revoke all on function t1_private.discord_card_kick_event() from public;
revoke execute on function public.discord_card_current(uuid) from public, anon, authenticated;
revoke execute on function public.discord_card_lost(uuid, text) from public, anon, authenticated;
grant execute on function public.discord_card_current(uuid) to service_role;
grant execute on function public.discord_card_lost(uuid, text) to service_role;
