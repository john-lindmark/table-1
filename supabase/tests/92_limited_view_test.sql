-- A Limited view's weekly and per-pair numbers (bug #15 rebuilt how limited_view gathers them; see 91 for the rest).
\ir _helpers.sql
set client_min_messages = notice;

select public.limited_run_open('TST', 'PremierDraft', 'game', 'https://x/game.csv.gz', '2026-10-17 12:00:00+00', 1000);
\set RUN '(select id from t1_private.limited_runs where set_code = ''TST'' and kind = ''game'')'
select public.limited_run_state(:RUN);
-- UB is missing in week 2, WR in week 3; Lightning Bolt has too few games in week 3 and with WR; Opt has no weeks.
select pg_temp.eq('one slice', public.limited_step_commit(:RUN, 0, 800, 'w', '', '{"cols": ["a"]}', 10,
  '{"T|a": [1000, 560], "T|t": [200, 120],
    "p|UB|a": [300, 180], "pw|UB|1|a": [100, 70], "pw|UB|3|a": [200, 110], "ps|UB|a": [30, 0], "pp|UB|a": [150, 95],
    "p|WR|a": [200, 90], "pw|WR|1|a": [50, 20], "pw|WR|2|a": [150, 70],
    "p|UB|t": [100, 60], "pw|UB|2|t": [100, 60],
    "cd|Lightning Bolt|a": [600, 350], "ch|Lightning Bolt|a": [600, 380],
    "cw|Lightning Bolt|1": [400, 250], "cw|Lightning Bolt|3": [150, 90],
    "cp|Lightning Bolt|UB": [300, 200], "cp|Lightning Bolt|WR": [100, 50],
    "cd|Lightning Bolt|t": [100, 60], "cd|Opt|a": [50, 25]}', true), 'done');

\set ALL '(public.limited_pack_facts(''TST'')->''events''->''PremierDraft''->''groups''->''all'')'
\set TOP '(public.limited_pack_facts(''TST'')->''events''->''PremierDraft''->''groups''->''top'')'
select pg_temp.eq('weeks', (:ALL->>'weeks') || ' ' || (:TOP->>'weeks'), '3 2');
select pg_temp.eq('pairs: weekly win rate (null in a week without games) and share of that week',
  (select string_agg((p->>'p') || ' ' || (p->>'week_wr') || ' ' || (p->>'week_share'), '; ' order by o)
     from jsonb_array_elements(:ALL->'pairs') with ordinality x(p, o)),
  'UB [0.7000, null, 0.5500] [0.6667, 0.0000, 1.0000]; WR [0.4000, 0.4667, null] [0.3333, 1.0000, 0.0000]');
select pg_temp.eq('pairs: splash, play and draw (none without play counts)',
  (select string_agg((p->>'p') || ' ' || (p->>'splash') || ' ' || coalesce(p->>'play_wr', '-') || ' ' || coalesce(p->>'draw_wr', '-'), '; ' order by o)
     from jsonb_array_elements(:ALL->'pairs') with ordinality x(p, o)),
  'UB 0.1000 0.6333 0.5667; WR 0.0000 - -');
select pg_temp.eq('cards: weekly GIH and pair GIH from 200 games, empty for a card without them',
  (select string_agg((c->>'n') || ' ' || (c->>'week_gih') || ' ' || (c->>'pair_gih'), '; ' order by o)
     from jsonb_array_elements(:ALL->'cards') with ordinality x(c, o)),
  'Lightning Bolt [0.6250, null, null] {"UB": 0.6667}; Opt [null, null, null] {}');
select pg_temp.eq('top players: their own weeks, no card weeks or pairs',
  (select (p->>'week_wr') || ' ' || (p->>'week_share') from jsonb_array_elements(:TOP->'pairs') p) || ' '
  || (select coalesce(c->>'week_gih', '-') || ' ' || coalesce(c->>'pair_gih', '-') from jsonb_array_elements(:TOP->'cards') c),
  '[null, 0.6000] [null, 1.0000] - -');
