-- Insights: the matchup grid puts your decks first (John, 2026-10-30): rows for archetypes you have a deck of, then
-- the ones your collection nearly builds. Contract: contract/insights-2026-10-24.md § What the viewer gets ("Yours").
--
-- insights_mine(p_format) answers for the signed-in account only:
--   decks:    each of your decks in the format with the archetype Insights' rules give it (meta_label, as Spice does);
--   coverage: for each archetype with a usual list, the share of that list's copies your collection holds (a card
--             counts up to the usual copies; any printing, finish or language; basic lands left out, as they are
--             never missing).
-- An archetype's usual list is every non-basic card in at least half of its main decks of the last 90 days (all
-- tiers), at its average copies rounded (at least 1). Kept per format and day in t1_private.meta_cores, filled by
-- the first call of the day.

create table if not exists t1_private.meta_cores (
  format text not null,
  built_on date not null,
  archetype_id integer not null,
  card uuid not null,
  copies integer not null,
  primary key (format, built_on, archetype_id, card)
);
revoke all on t1_private.meta_cores from public, anon, authenticated;

create or replace function t1_private.meta_cores_for(p_format text, p_today date default current_date)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from t1_private.meta_cores where format = p_format and built_on = p_today) then return; end if;
  delete from t1_private.meta_cores where format = p_format and built_on < p_today;
  insert into t1_private.meta_cores (format, built_on, archetype_id, card, copies)
  select p_format, p_today, x.a, x.card, greatest(1, round(x.q / x.n))::int
    from (select d.archetype_id a, u.card, count(*) n, sum(u.q)::numeric q, max(t.lists) lists
            from t1_private.meta_decks d
            cross join lateral unnest(d.main, d.main_qty) u(card, q)
            join (select archetype_id, count(*) lists from t1_private.meta_decks
                   where format = p_format and on_date > p_today - 90 and on_date <= p_today and archetype_id <> 0
                   group by archetype_id) t on t.archetype_id = d.archetype_id
           where d.format = p_format and d.on_date > p_today - 90 and d.on_date <= p_today and d.archetype_id <> 0
           group by d.archetype_id, u.card) x
    join public.card_oracles o on o.oracle_id = x.card
   where x.n * 2 >= x.lists and coalesce(o.type_line, '') !~ 'Basic'
  on conflict do nothing;
end $$;

create or replace function public.insights_mine(p_format text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_decks jsonb;
  v_cover jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if not exists (select 1 from t1_private.meta_formats where format = p_format) then
    raise exception 'Unknown format' using errcode = '22023';
  end if;
  perform t1_private.meta_cores_for(p_format);

  select coalesce(jsonb_agg(jsonb_build_object('a', y.a, 'id', y.id, 'name', y.name) order by y.updated_at desc), '[]'::jsonb) into v_decks
    from (select l.id, l.name, l.updated_at,
                 t1_private.meta_label(p_format, x.main, x.side, t1_private.meta_colors(x.main, x.qty)) a
            from (select cl.id, cl.name, cl.updated_at from public.card_lists cl
                   where cl.user_id = v_uid and cl.kind = 'deck' and cl.format = p_format and cl.deleted_at is null
                   order by cl.updated_at desc limit 100) l
            cross join lateral (
              select coalesce(array_agg(c.oracle_id) filter (where e.board in ('main', 'commander')), '{}') main,
                     coalesce(array_agg(e.qty::smallint) filter (where e.board in ('main', 'commander')), '{}') qty,
                     coalesce(array_agg(c.oracle_id) filter (where e.board = 'side'), '{}') side
                from public.card_list_entries e join public.cards c on c.id = e.card_id
               where e.list_id = l.id) x) y;

  select coalesce(jsonb_agg(jsonb_build_object('a', a, 'have', have) order by have desc, a), '[]'::jsonb) into v_cover
    from (select k.archetype_id a, round(sum(least(coalesce(o.n, 0), k.copies))::numeric / sum(k.copies), 3) have
            from t1_private.meta_cores k
            left join (select c.oracle_id, sum(ci.qty) n from public.collection_items ci join public.cards c on c.id = ci.card_id
                        where ci.user_id = v_uid and ci.qty > 0 group by c.oracle_id) o on o.oracle_id = k.card
           where k.format = p_format and k.built_on = current_date
           group by k.archetype_id) z;

  return jsonb_build_object('decks', v_decks, 'coverage', v_cover);
end $$;

revoke execute on function t1_private.meta_cores_for(text, date) from public, anon, authenticated;
revoke execute on function public.insights_mine(text) from public, anon;
grant execute on function public.insights_mine(text) to authenticated;
