-- meta_state_put's update had no WHERE (meta_settings has one row), which the live API's pg_safeupdate refuses:
-- "UPDATE requires a WHERE clause" stopped the first MTGO tick on 2026-10-25. Guarded by 91_insights_test.sql.
create or replace function public.meta_state_put(p_patch jsonb)
returns jsonb language sql security definer set search_path = '' as $$
  update t1_private.meta_settings set state = state || coalesce(p_patch, '{}'::jsonb) where id returning state;
$$;
