-- Spoiler season (20261030170000_limited_rankable_spoilers.sql): upcoming sets are rankable from 75 days out with 20+
-- cards spoiled; released sets still need 60+.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000058a1', 'ana@example.com', '{"full_name": "Ana Lind"}');
-- SPL: out in 70 days, 25 cards spoiled. FAR: 80 days out. FEW: out in 10 days, 19 cards. OUT: out last week, 25 cards.
insert into public.mtg_sets (code, name, set_type, released_at, card_count) values
  ('spl', 'Spoiled Now', 'expansion', current_date + 70, 25),
  ('far', 'Far Away', 'expansion', current_date + 80, 25),
  ('few', 'Few Spoiled', 'expansion', current_date + 10, 19),
  ('out', 'Out Already', 'expansion', current_date - 7, 25);
create or replace function pg_temp.fill(p_set text, p_base int, p_n int) returns void language sql as $$
  insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, source_card_id, source_rank, content_hash)
  select ('c0000000-0000-0000-0058-' || lpad((p_base + n)::text, 12, '0'))::uuid, p_set || ' card ' || n, p_set || ' card ' || n,
         'normal', 'Creature', ('c1000000-0000-0000-0058-' || lpad((p_base + n)::text, 12, '0'))::uuid, 'a', 'h'
    from generate_series(1, p_n) n;
  insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash)
  select ('c1000000-0000-0000-0058-' || lpad((p_base + n)::text, 12, '0'))::uuid,
         ('c0000000-0000-0000-0058-' || lpad((p_base + n)::text, 12, '0'))::uuid, p_set, n::text, 'en', 'common', '{nonfoil}', 'normal', 'h'
    from generate_series(1, p_n) n;
$$;
select pg_temp.fill('spl', 0, 25), pg_temp.fill('far', 100, 25), pg_temp.fill('few', 200, 19), pg_temp.fill('out', 300, 25);

set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000058a1');
select pg_temp.eq('an upcoming set with 20+ cards spoiled, up to 75 days out, is rankable; a released one still needs 60',
  (select string_agg((x->>'key') || ' ' || (x->>'cards') || ' ' || (x->>'pack'), ', ')
     from jsonb_array_elements(public.limited_rankable()) x), 'SPL 25 false');
select pg_temp.eq('so anyone can start ranking it', public.cube_ranking_create('f5800000-0000-0000-0000-000000000001', p_set => 'SPL')->>'set_key', 'SPL');
select pg_temp.as_user(null);
select pg_temp.throws('signed out sees none', $$select public.limited_rankable()$$, '28000');
