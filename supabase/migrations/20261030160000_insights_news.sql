-- Tell people when Insights gains something (John, 2026-10-30: "notify users when new formats become available";
-- contract/insights-2026-10-24.md § New in Insights). One `insights.new` push, once per thing:
--  - `data`: a pack appears for the first time: a Constructed format, a set's 17Lands draft data, a new Arena cube
--    version (a trigger on t1_private.insight_packs, which only grows by a new key).
--  - `rank`: a new paper set can be ranked before its draft data exists: released within the last 14 days or the next
--    10, at least 100 of its cards in the catalog, no pack yet (hourly, t1_private.insights_rank_ready).
-- Who: everyone who opened Insights in the last 60 days (insights_index records each account once a day in
-- t1_private.insights_viewers), unless they turned "New in Insights" off (insights_alerts_set, which mutes the kind in
-- notification_prefs like want_alerts_set). Sent in batches of 200 accounts; the apps open the format, set or its
-- rankings. What's already there when this goes live is marked as told, so nobody gets a burst.
-- Replaces public.insights_index (20261025120000; now volatile, plpgsql).

create table if not exists t1_private.insights_viewers (
  user_id uuid primary key references auth.users (id) on delete cascade,
  seen_at timestamptz not null default now()
);
create index if not exists insights_viewers_seen_idx on t1_private.insights_viewers (seen_at);

create table if not exists t1_private.insights_news (
  kind text not null check (kind in ('constructed', 'limited')),
  key text not null,
  what text not null check (what in ('data', 'rank')),
  name text not null,
  recipients integer not null default 0,
  sent_at timestamptz not null default now(),
  primary key (kind, key, what)
);

create or replace function public.insights_index()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return '[]'::jsonb; end if;
  insert into t1_private.insights_viewers as v (user_id, seen_at) values (v_uid, now())
  on conflict (user_id) do update set seen_at = now() where v.seen_at < now() - interval '1 day';
  return (select coalesce(jsonb_agg(jsonb_build_object(
             'kind', p.kind, 'key', p.key, 'name', p.name, 'version', p.version,
             'url', 'https://aaozhfcbvqrgkkrihkrd.supabase.co/storage/v1/object/public/catalog/' || p.path,
             'bytes', p.bytes, 'built_at', p.built_at, 'through', p.through::text)
           order by p.kind, p.ord, p.key), '[]'::jsonb)
            from t1_private.insight_packs p);
end $$;

-- Sends one piece of news once. Returns how many accounts it went to (0 when it was already sent).
create or replace function t1_private.insights_announce(p_kind text, p_key text, p_name text, p_what text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_users uuid[];
  v_n integer := 0;
  i integer;
begin
  insert into t1_private.insights_news (kind, key, what, name) values (p_kind, p_key, p_what, coalesce(p_name, p_key))
  on conflict do nothing;
  if not found then return 0; end if;
  select array_agg(v.user_id order by v.user_id) into v_users
    from t1_private.insights_viewers v
   where v.seen_at > now() - interval '60 days'
     and exists (select 1 from public.devices d where d.user_id = v.user_id)
     and not exists (select 1 from public.notification_prefs np where np.user_id = v.user_id and 'insights.new' = any (np.muted_kinds));
  v_n := coalesce(cardinality(v_users), 0);
  i := 1;
  while i <= v_n loop
    perform public.enqueue_notification('insights.new', null, v_users[i:i + 199], jsonb_build_object(
      'insights_section', p_kind, 'insights_key', p_key, 'name', coalesce(p_name, p_key), 'what', p_what));
    i := i + 200;
  end loop;
  update t1_private.insights_news set recipients = v_n where kind = p_kind and key = p_key and what = p_what;
  return v_n;
end $$;

create or replace function t1_private.insights_pack_news_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.insights_announce(new.kind, new.key, new.name, 'data');
  return null;
end $$;
drop trigger if exists insight_packs_news on t1_private.insight_packs;
create trigger insight_packs_news after insert on t1_private.insight_packs
  for each row execute function t1_private.insights_pack_news_trg();

-- New paper sets ready to rank before their 17Lands data. Returns how many were announced.
create or replace function t1_private.insights_rank_ready()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  s record;
  v integer := 0;
begin
  for s in
    select upper(m.code) k, m.name from public.mtg_sets m
     where not m.digital and m.set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'remastered')
       and m.released_at between current_date - 14 and current_date + 10
       and not exists (select 1 from t1_private.insights_news n where n.kind = 'limited' and n.key = upper(m.code))
       and not exists (select 1 from t1_private.insight_packs p where p.kind = 'limited' and p.key = upper(m.code))
       and (select count(*) from t1_private.limited_set_printings(m.code)) >= 100
  loop
    perform t1_private.insights_announce('limited', s.k, s.name, 'rank');
    v := v + 1;
  end loop;
  return v;
end $$;

-- "New in Insights" on or off (mutes the push kind).
create or replace function public.insights_alerts()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return jsonb_build_object('on', not exists (select 1 from public.notification_prefs np
                                               where np.user_id = v_uid and 'insights.new' = any (np.muted_kinds)));
end $$;

create or replace function public.insights_alerts_set(p_on boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_was boolean;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_on is null then raise exception 'p_on is required' using errcode = '22023'; end if;
  v_was := (public.insights_alerts()->>'on')::boolean;
  if v_was <> p_on then
    insert into public.notification_prefs as np (user_id, muted_kinds)
    values (v_uid, case when p_on then '{}'::text[] else array['insights.new'] end)
    on conflict (user_id) do update
      set muted_kinds = case when p_on then array_remove(np.muted_kinds, 'insights.new')
                             else array_append(array_remove(np.muted_kinds, 'insights.new'), 'insights.new') end,
          updated_at = now();
    perform t1_private.account_audit(v_uid, 'insights_alerts.set', null,
                                     jsonb_build_object('alerts', v_was), jsonb_build_object('alerts', p_on));
  end if;
  return jsonb_build_object('on', p_on);
end $$;

-- What's there now counts as told.
insert into t1_private.insights_news (kind, key, what, name)
select kind, key, 'data', name from t1_private.insight_packs on conflict do nothing;
insert into t1_private.insights_news (kind, key, what, name)
select 'limited', key, 'data', name from t1_private.limited_cube_versions on conflict do nothing;
insert into t1_private.insights_news (kind, key, what, name)
select 'limited', upper(m.code), 'rank', m.name from public.mtg_sets m
 where not m.digital and m.set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'remastered')
   and m.released_at between current_date - 14 and current_date + 10
on conflict do nothing;

revoke all on function t1_private.insights_announce(text, text, text, text) from public, anon, authenticated;
revoke all on function t1_private.insights_pack_news_trg() from public, anon, authenticated;
revoke all on function t1_private.insights_rank_ready() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['insights_index()', 'insights_alerts()', 'insights_alerts_set(boolean)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-insights-rank-ready') then
      perform cron.schedule('t1-insights-rank-ready', '53 * * * *', 'select t1_private.insights_rank_ready()');
    end if;
  end if;
end $$;
