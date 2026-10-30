-- Bug #23: each meta-sync build relabels the format's Other decks (meta_relabel(format, true)), and live Standard
-- had 21,000 of them. meta_label is a SQL function with its own search_path, so Postgres can't inline it: it ran as
-- a separate query per deck (4.7 s for Standard's Other on live) and the build's call passed the 8 s statement
-- timeout. The same rule as t1_private.meta_label (20261025180000_insights_colour_rules), joined laterally, lets
-- the planner memoize repeated lists and runs in 0.3 s there. Keep the two in step: 91_insights_test.sql checks
-- that a relabel lands where meta_label does.
create or replace function public.meta_relabel(p_format text, p_other_only boolean default false)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform t1_private.meta_rule_compile(id) from t1_private.meta_archetypes where format = p_format and status = 'approved';
  update t1_private.meta_decks d set archetype_id = l.a
    from (select x.id, coalesce(r.id, 0) a
            from t1_private.meta_decks x
            left join lateral (
              select a.id from t1_private.meta_archetypes a
               where a.format = x.format and a.status = 'approved' and not a.blocked
                 and ((cardinality(a.r_main) + cardinality(a.r_deck) + coalesce(cardinality(a.r_any1), 0)) > 0 or a.r_colors is not null)
                 and (a.r_colors is null or a.r_colors = x.colors)
                 and a.r_main <@ x.main
                 and a.r_deck <@ (x.main || x.side)
                 and (a.r_any1 is null or a.r_any1 && (x.main || x.side))
                 and (a.r_any2 is null or a.r_any2 && (x.main || x.side))
                 and (a.r_any3 is null or a.r_any3 && (x.main || x.side))
                 and not (a.r_not && (x.main || x.side))
               order by a.priority, a.id limit 1) r on true
           where x.format = p_format and (not p_other_only or x.archetype_id = 0)) l
   where d.id = l.id and d.archetype_id is distinct from l.a;
  get diagnostics n = row_count;
  return n;
end $$;
