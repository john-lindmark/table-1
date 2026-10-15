-- Scan reports: when someone corrects a scanned card, the app sends the OCR text of the frames that led to the take,
-- what the matcher picked and what the card really was. Exported to testdata/scan/reports/ as matcher test cases
-- (testdata/scan/tools/export_reports.py). Text only, never images. On by default; Account → "Improve scanning"
-- turns it off on that device.
-- Clients can only insert, through scan_report; nobody but the service role reads them. A report is its own
-- append-only record (no audit_log row: that log is per event).

create table if not exists public.scan_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete set null,
  kind text not null check (kind in ('wrong_card', 'wrong_printing', 'removed')),
  platform text not null check (platform in ('ios', 'android', 'web')),
  app_version text,
  pack_version text,
  owned_only boolean not null default false,       -- matched against owned cards only (Trades: what you give)
  frames jsonb not null,                            -- [[line, …], …] oldest first: the matcher's input
  -- {card_id, exact, name, set, cn}; name/set/cn resolved from the catalog when the report arrives
  matched jsonb not null,
  corrected jsonb,                                  -- {card_id, name, set, cn}; null when removed as wrong
  created_at timestamptz not null default now()
);
create index if not exists scan_reports_created_idx on public.scan_reports (created_at);
create index if not exists scan_reports_user_idx on public.scan_reports (user_id, created_at desc);
alter table public.scan_reports enable row level security;
revoke all on public.scan_reports from public, anon, authenticated;

-- {card_id, name, set, cn} for a printing, or just {card_id} when the catalog doesn't know it.
create or replace function t1_private.scan_card(p_card_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('card_id', c.id, 'name', o.name, 'set', c.set_code, 'cn', c.collector_number)
       from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id where c.id = p_card_id),
    jsonb_build_object('card_id', p_card_id));
$$;
revoke execute on function t1_private.scan_card(uuid) from public;

-- Records one correction. Frames: at most 12, 80 lines each, 300 characters a line (longer lines are cut).
create or replace function public.scan_report(
  p_kind text, p_platform text, p_frames jsonb, p_matched_card_id uuid, p_matched_exact boolean,
  p_corrected_card_id uuid default null, p_app_version text default null, p_pack_version text default null,
  p_owned_only boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_frames jsonb;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_kind not in ('wrong_card', 'wrong_printing', 'removed') then
    raise exception 'Unknown report kind' using errcode = '22023';
  end if;
  if (p_kind = 'removed') <> (p_corrected_card_id is null) then
    raise exception 'A correction names the right card; a removal doesn''t' using errcode = '22023';
  end if;
  if p_matched_card_id is null then raise exception 'Which card was scanned?' using errcode = '22023'; end if;
  if p_frames is null or jsonb_typeof(p_frames) <> 'array' or jsonb_array_length(p_frames) > 12
     or exists (select 1 from jsonb_array_elements(p_frames) f where jsonb_typeof(f) <> 'array' or jsonb_array_length(f) > 80) then
    raise exception 'Frames must be at most 12 lists of at most 80 lines' using errcode = '22023';
  end if;
  if (select count(*) from public.scan_reports where user_id = v_uid and created_at > now() - interval '1 day') >= 200 then
    raise exception 'Too many scan reports today' using errcode = '53400';
  end if;

  select coalesce(jsonb_agg(
           (select coalesce(jsonb_agg(left(l #>> '{}', 300) order by j), '[]'::jsonb)
              from jsonb_array_elements(f) with ordinality as x(l, j)
             where jsonb_typeof(l) = 'string')
           order by i), '[]'::jsonb)
    into v_frames
    from jsonb_array_elements(p_frames) with ordinality as y(f, i);

  insert into public.scan_reports (user_id, kind, platform, app_version, pack_version, owned_only, frames, matched, corrected)
  values (v_uid, p_kind, p_platform, left(p_app_version, 40), left(p_pack_version, 80), coalesce(p_owned_only, false), v_frames,
          t1_private.scan_card(p_matched_card_id) || jsonb_build_object('exact', coalesce(p_matched_exact, false)),
          case when p_corrected_card_id is null then null else t1_private.scan_card(p_corrected_card_id) end)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.scan_report(text, text, jsonb, uuid, boolean, uuid, text, text, boolean) from public, anon;
grant execute on function public.scan_report(text, text, jsonb, uuid, boolean, uuid, text, text, boolean) to authenticated;

-- Account deletion keeps scan reports (card text only, useful as test cases) but drops who sent them.
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  perform public.demo_remove();
  update public.profiles
     set handle = null, display_name = 'Deleted player', avatar_url = null,
         deleted_at = now(), updated_at = now()
   where id = v_uid;
  update public.participants set display_name = 'Deleted player' where user_id = v_uid;
  delete from public.devices where user_id = v_uid;
  delete from public.notification_prefs where user_id = v_uid;
  delete from public.presence_cells where user_id = v_uid;
  delete from public.event_invites where user_id = v_uid and status = 'pending';
  delete from public.trades where user_id = v_uid;
  delete from public.collection_ledger where user_id = v_uid;
  delete from public.collection_batches where user_id = v_uid;
  delete from public.collection_items where user_id = v_uid;
  delete from public.card_lists where user_id = v_uid;   -- versions and entries cascade
  delete from public.library_summary where user_id = v_uid;
  update public.scan_reports set user_id = null where user_id = v_uid;
end $$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
