-- Table 1 Events V1: ops alerts and scheduled jobs (applied live as events_v1_i_ops_jobs).
-- Auto-confirm is not a job: results confirm when their round ends (rounds_confirm_on_end trigger).
-- Deferred to the edge-function phase: notify-worker sweep (every 10 s), presence expiry and
-- idempotency purge (both are bulk deletes that need owner approval in the Supabase connector).

create table public.ops_alerts (
  id uuid primary key default public.uuid_v7(),
  kind text not null,
  detail jsonb,
  at timestamptz not null default now()
);
alter table public.ops_alerts enable row level security;   -- no policy: service role only

-- Records drift check: expect zero rows every night.
select cron.schedule('t1-records-drift', '27 4 * * *', $$
  insert into public.ops_alerts (kind, detail)
  select 'records.drift', to_jsonb(d) from public.records_drift() d
$$);

-- Applied later on 2026-10-06 (events_v1_l_cleanup_jobs, events_v1_m_pg_net):
select cron.schedule('t1-presence-expire', '7 * * * *',
  $$ delete from public.presence_cells where seen_at < now() - interval '3 hours' $$);
select cron.schedule('t1-purge-idempotency', '17 4 * * *',
  $$ delete from public.rpc_idempotency where created_at < now() - interval '1 day' $$);
create extension if not exists pg_net with schema extensions;
