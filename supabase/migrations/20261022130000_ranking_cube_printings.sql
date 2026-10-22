-- The ranker shows each card as the cube has it (John, 2026-10-22): cube_ranking_get's cube also carries
-- `printings`, {oracle id: card id}, the main-board printing the cube holds most copies of (ties: the lowest card id).
-- Clients draw that printing and fall back to the card's usual art when the catalog doesn't have it
-- (contract/cube-rankings-2026-10-21.md, "Server").

create or replace function public.cube_ranking_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
  v_cube jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id;
  if r.id is null or not t1_private.ranking_seen(r, v_uid) then raise exception 'That''s private' using errcode = '42501'; end if;
  v_cube := t1_private.cube_json(r.list_id, v_uid);
  if (v_cube->>'can_see')::boolean then
    v_cube := v_cube || jsonb_build_object('cards', (
      select coalesce(jsonb_agg(o order by o), '[]'::jsonb)
        from (select distinct c.oracle_id::text o from public.card_list_entries e join public.cards c on c.id = e.card_id
               where e.list_id = r.list_id and e.board = 'main' and e.qty > 0) d),
      'printings', (
      select coalesce(jsonb_object_agg(o, card), '{}'::jsonb)
        from (select distinct on (o) o, card
                from (select c.oracle_id::text o, e.card_id::text card, sum(e.qty) q
                        from public.card_list_entries e join public.cards c on c.id = e.card_id
                       where e.list_id = r.list_id and e.board = 'main' and e.qty > 0
                       group by 1, 2) p
               order by o, q desc, card) d));
  end if;
  return t1_private.ranking_json(r, v_uid) || jsonb_build_object('log', r.screens, 'changes', r.changes, 'cube', v_cube);
end $$;
