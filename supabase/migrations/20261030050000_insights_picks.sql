-- Insights picks follow the account (John, 2026-10-29: "Settings for insights format views should be maintained
-- across platforms"; contract/insights-2026-10-24.md § What the viewer picked). Each client kept the Insights picks
-- on the device; now they live on the account's own user_settings row (owner-only RLS, written directly like
-- tracker_mode), as one object:
--   {section, format, tier, days, set, event, group, hidden_formats: [...], hidden_sets: [...]}
-- Every key is optional; clients keep what they don't know. Small by construction, so the check caps it.
alter table public.user_settings add column if not exists insights jsonb not null default '{}'::jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'user_settings_insights_shape') then
    alter table public.user_settings add constraint user_settings_insights_shape
      check (jsonb_typeof(insights) = 'object' and pg_column_size(insights) <= 4096);
  end if;
end $$;
