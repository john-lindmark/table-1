-- Scan reports follow what people already do instead of asking them (contract/trades-2026-10-16.md, Scanning):
-- removed (deleted a scanned card), wrong_card (deleted it, then added another card by hand), wrong_printing
-- (changed the printing), and missed (nothing was taken, then a card was added by hand). A miss has no match.

alter table public.scan_reports drop constraint if exists scan_reports_kind_check;
alter table public.scan_reports add constraint scan_reports_kind_check
  check (kind in ('wrong_card', 'wrong_printing', 'removed', 'missed'));
alter table public.scan_reports alter column matched drop not null;

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
  if p_kind not in ('wrong_card', 'wrong_printing', 'removed', 'missed') then
    raise exception 'Unknown report kind' using errcode = '22023';
  end if;
  if (p_kind = 'removed') <> (p_corrected_card_id is null) then
    raise exception 'A correction names the right card; a removal doesn''t' using errcode = '22023';
  end if;
  if (p_kind = 'missed') <> (p_matched_card_id is null) then
    raise exception 'A miss has no matched card; every other report does' using errcode = '22023';
  end if;
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
          case when p_matched_card_id is null then null
               else t1_private.scan_card(p_matched_card_id) || jsonb_build_object('exact', coalesce(p_matched_exact, false)) end,
          case when p_corrected_card_id is null then null else t1_private.scan_card(p_corrected_card_id) end)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.scan_report(text, text, jsonb, uuid, boolean, uuid, text, text, boolean) from public, anon;
grant execute on function public.scan_report(text, text, jsonb, uuid, boolean, uuid, text, text, boolean) to authenticated;
