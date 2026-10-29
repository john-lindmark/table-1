-- /event results for events the bot never posted (John, 2026-10-29: his team draft, run from the app, wasn't offered).
-- The picker now offers your own finished events as well as the server's, and posting results for an event that
-- isn't in this server yet puts it there first (organizers, or players of a non-private event, as /event post).

-- discord_my_events (from 20261029170000) plus p_state: 'open' (the default: setup / seated / in progress, soonest
-- first) or 'done' (completed / archived in the last year, newest first).
create or replace function public.discord_my_events(p_discord_id text, p_query text default null, p_limit integer default 25,
  p_state text default 'open')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  v_q text := nullif(trim(coalesce(p_query, '')), '');
  v_done boolean := coalesce(p_state, 'open') = 'done';
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('event_id', x.id, 'name', x.name, 'format_label', x.format_label, 'status', x.status,
                                        'starts_at', x.starts_at, 'role', x.role, 'players', t1_private.active_players(x.id))
                    order by x.ord)
      from (
        select e.id, e.name, e.format_label, e.status, e.starts_at, e.created_at,
               case when exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = v_uid) then 'organizer' else 'player' end role,
               row_number() over (order by case when v_done then e.updated_at end desc,
                                           case when not v_done then e.starts_at end asc nulls last, e.created_at desc) ord
          from public.events e
         where not e.is_demo
           and case when v_done then e.status in ('completed', 'archived') and e.updated_at > now() - interval '1 year'
                    else e.status in ('setup', 'seated', 'in_progress') end
           and (exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = v_uid)
                or exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = v_uid))
           and (v_q is null or e.name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
         order by ord
         limit least(greatest(coalesce(p_limit, 25), 1), 25)) x), '[]'::jsonb);
end $$;
drop function if exists public.discord_my_events(text, text, integer);
revoke execute on function public.discord_my_events(text, text, integer, text) from public, anon, authenticated;
grant execute on function public.discord_my_events(text, text, integer, text) to service_role;

-- discord_event_results (from 20261029130000) plus p_channel_id: an event not yet in this server is put there first
-- when the caller may post it (the same rule as discord_event_attach); then the results rules as before.
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
  return jsonb_build_object('final', v_final, 'organizer', v_org) || t1_private.discord_event_json(p_event_id);
end $$;
drop function if exists public.discord_event_results(text, text, uuid);
revoke execute on function public.discord_event_results(text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.discord_event_results(text, text, uuid, text) to service_role;
