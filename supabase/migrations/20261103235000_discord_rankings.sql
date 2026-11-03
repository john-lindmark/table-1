-- /ranking (contract/discord-2026-10-29.md § Rankings): post a cube or Limited set ranking you made, its final top 50 or
-- 100 or one color's list. The bot works the lists out with the rankings engine (ranking-brief's cubeRanking.ts, the
-- web's copy), so the database hands it the ranking as cube_ranking_get does, made as the linked account, plus each of
-- the subject's cards with what its color is read from. Service role only, like every discord_* function.

-- Your rankings for the picker, newest first: cubes still there and Limited sets. Matched on the cube's or set's name,
-- the set's code or the ranking's label.
create or replace function public.discord_my_rankings(p_discord_id text, p_query text default null, p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  v_q text := nullif(replace(replace(btrim(coalesce(p_query, '')), '%', ''), '_', ''), '');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'subject', x.subject, 'kind', x.kind, 'set', x.set_key, 'name', x.name,
                                        'top', x.top_size, 'ranked', x.ranked, 'sorted', x.sorted, 'categories', x.categories)
                     order by x.updated_at desc, x.id)
      from (
        select r.id, r.name, r.set_key, r.top_size, r.ranked, r.sorted, r.categories, r.updated_at, s.kind, s.subject
          from public.cube_rankings r
          left join public.card_lists l on l.id = r.list_id and l.deleted_at is null
          cross join lateral (
            select case when r.set_key is not null then 'set' else 'cube' end kind,
                   coalesce(case when r.set_key is not null then t1_private.set_subject_json(r.set_key)->>'name' else l.name end,
                            r.set_key, '') subject) s
         where r.user_id = v_uid and (r.set_key is not null or l.id is not null)
           and (v_q is null or s.subject ilike '%' || v_q || '%' or r.name ilike '%' || v_q || '%'
                or coalesce(r.set_key, '') ilike '%' || v_q || '%')
         order by r.updated_at desc, r.id
         limit least(greatest(coalesce(p_limit, 25), 1), 25)) x), '[]'::jsonb);
end $$;

-- One of your rankings to post: cube_ranking_get's answer without the change log, `cards` (the subject's cards now;
-- the baseline when you can no longer see the cube) and `facts` [oracle id, name, type line, mana cost, colors] for
-- each of them. Someone else's ranking is refused, even one you can see (/ranking posts your own), as is one of a deleted cube.
create or replace function public.discord_ranking(p_discord_id text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  v jsonb;
  v_cards jsonb;
  v_facts jsonb;
begin
  if p_id is null or not exists (select 1 from public.cube_rankings r where r.id = p_id and r.user_id = v_uid
                                   and (r.set_key is not null
                                        or exists (select 1 from public.card_lists l where l.id = r.list_id and l.deleted_at is null))) then
    raise exception 'Pick one of your rankings from the list' using errcode = '22023';
  end if;
  v := public.cube_ranking_get(p_id) - 'changes';
  v_cards := coalesce(v->'cube'->'cards', v->'baseline', '[]'::jsonb);
  select coalesce(jsonb_agg(jsonb_build_array(o.oracle_id, o.name, o.type_line, o.mana_cost, to_jsonb(o.colors)) order by o.oracle_id), '[]'::jsonb)
    into v_facts
    from public.card_oracles o
   where o.oracle_id in (select x::uuid from jsonb_array_elements_text(v_cards) x);
  if v->'cube' is not null and jsonb_typeof(v->'cube') = 'object' then
    v := jsonb_set(v, '{cube}', (v->'cube') - 'cards');
  end if;
  return v || jsonb_build_object('cards', v_cards, 'facts', v_facts);
end $$;

do $$
declare f text;
begin
  foreach f in array array['discord_my_rankings(text, text, integer)', 'discord_ranking(text, uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
