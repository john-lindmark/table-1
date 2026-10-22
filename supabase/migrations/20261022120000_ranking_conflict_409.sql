-- A stale push answers 409 (SQLSTATE PT409) instead of 40001 (contract/cube-rankings-2026-10-21.md, "Server").
-- PostgREST retries a transaction that fails with 40001 (serialization_failure) and keeps retrying while it fails,
-- so every stale push held an API connection in a once-a-second loop. Overnight 2026-10-22 one push looped for nine
-- hours; by morning about 20 held the whole pool and every request on the project timed out (PGRST003, 504). PT409
-- reaches the client at once as HTTP 409 with code "PT409". Applied to live 2026-10-22 during the outage (the same
-- one-line change, made in place); nothing else in the function changed.
-- Never raise 40001 or 40P01 from an RPC.

create or replace function public.cube_ranking_push(
  p_id uuid, p_rev integer, p_keep integer, p_add jsonb default '[]'::jsonb,
  p_sorted integer default null, p_categories integer default null, p_ranked integer default null, p_op_id uuid default null,
  p_changes jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
  v_add jsonb := coalesce(p_add, '[]'::jsonb);
  v_changes jsonb := coalesce(p_changes, '[]'::jsonb);
  v_keep jsonb;
  v_bad text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id for update;
  if r.id is null or r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
  if p_op_id is not null and r.last_op = p_op_id then return t1_private.ranking_json(r, v_uid); end if;
  if p_rev is distinct from r.rev then
    raise exception 'This ranking changed on another device' using errcode = 'PT409';
  end if;
  if p_keep is null or p_keep < 0 or p_keep > r.screen_count then
    raise exception 'Keep between 0 and % screens', r.screen_count using errcode = '22023';
  end if;
  if jsonb_typeof(v_add) <> 'array' then raise exception 'Screens come as a list' using errcode = '22023'; end if;
  if jsonb_array_length(v_add) > 1000 or p_keep + jsonb_array_length(v_add) > 6000 then
    raise exception 'At most 6000 screens in a ranking' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(v_add) e
              where jsonb_typeof(e) <> 'object'
                 or coalesce(e->>'s', '') not in ('W', 'U', 'B', 'R', 'G', 'M', 'C', 'L', 'F', 'P')
                 or jsonb_typeof(e->'o') is distinct from 'array'
                 or jsonb_array_length(e->'o') not between 2 and case when e->>'s' = 'P' then 15 else 4 end
                 or (e ? 't' and jsonb_typeof(e->'t') <> 'number')
                 or exists (select 1 from jsonb_array_elements(e->'o') x
                             where jsonb_typeof(x) <> 'string'
                                or x #>> '{}' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
                 or (select count(distinct x) from jsonb_array_elements_text(e->'o') x) <> jsonb_array_length(e->'o')) then
    raise exception 'A screen is 2 to 4 different cards (a pick, up to 15) and a session' using errcode = '22023';
  end if;
  if jsonb_typeof(v_changes) <> 'array' or jsonb_array_length(v_changes) > 2000
     or exists (select 1 from jsonb_array_elements(v_changes) e
                 where jsonb_typeof(e) <> 'object'
                    or coalesce(e->>'s', '') not in ('W', 'U', 'B', 'R', 'G', 'M', 'C', 'L', 'F')
                    or coalesce(e->>'c', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                    or jsonb_typeof(coalesce(e->'f', 'null')) not in ('null', 'number')
                    or jsonb_typeof(coalesce(e->'to', 'null')) not in ('null', 'number')
                    or coalesce(e->>'by', 'screen') not in ('screen', 'undo', 'redo', 'pick', 'pick_win', 'settings')) then
    raise exception 'A change is a list, a card and its places' using errcode = '22023';
  end if;
  select string_agg(distinct x, ', ') into v_bad
    from jsonb_array_elements(v_add) e, jsonb_array_elements_text(e->'o') x
   where not exists (select 1 from public.card_oracles o where o.oracle_id = x::uuid);
  if v_bad is not null then raise exception 'Unknown card: %', v_bad using errcode = '22023'; end if;

  select coalesce(jsonb_agg(e order by n), '[]'::jsonb) into v_keep
    from jsonb_array_elements(r.screens) with ordinality x(e, n) where n <= p_keep;
  update public.cube_rankings set
    screens = v_keep || coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('s', e->'s', 'o', e->'o', 't', e->'t'))
                                                   order by n)
                                    from jsonb_array_elements(v_add) with ordinality y(e, n)), '[]'::jsonb),
    screen_count = p_keep + jsonb_array_length(v_add),
    changes = (select coalesce(jsonb_agg(e order by n), '[]'::jsonb)
                 from jsonb_array_elements(changes || (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                          's', e->'s', 'c', e->'c', 'f', e->'f', 'to', e->'to', 't', e->'t', 'by', e->'by', 'n', e->'n')) order by n), '[]'::jsonb)
                                                         from jsonb_array_elements(v_changes) with ordinality y(e, n)))
                      with ordinality x(e, n)
                where n > jsonb_array_length(changes) + jsonb_array_length(v_changes) - 5000),
    rev = rev + 1, last_op = p_op_id,
    sorted = least(greatest(coalesce(p_sorted, sorted), 0), 8),
    categories = least(greatest(coalesce(p_categories, categories), 0), 8),
    ranked = least(greatest(coalesce(p_ranked, ranked), 0), top_size),
    updated_at = now()
   where id = p_id returning * into r;
  return t1_private.ranking_json(r, v_uid);
end $$;
