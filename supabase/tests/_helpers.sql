-- Shared test helpers. Include with `\ir _helpers.sql` at the top of a *_test.sql file.
--   pg_temp.as_user(uuid)          act as this account (auth.uid()); null = signed out
--   pg_temp.eq(label, got, want)   compare as text; prints "ok  label" or fails the file
--   pg_temp.throws(label, sql, sqlstate?)  the statement must raise (optionally with this SQLSTATE)
--   pg_temp.ms(label, sql, budget_ms, runs?)  times a statement (best of runs); perf files only
\set ON_ERROR_STOP 1
\set QUIET 1

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text, ''), false);
  perform set_config('request.jwt.claim.role', case when p is null then 'anon' else 'authenticated' end, false);
end $$;

create or replace function pg_temp.eq(label text, got text, want text) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
  raise notice 'ok  %', label;
end $$;

create or replace function pg_temp.throws(label text, stmt text, state text default null) returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin
    execute stmt;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if state is not null and v_state <> state then
      raise exception 'FAIL %: raised % (%), want %', label, v_state, v_msg, state;
    end if;
    raise notice 'ok  %', label;
    return;
  end;
  raise exception 'FAIL %: did not raise', label;
end $$;

create or replace function pg_temp.ms(label text, stmt text, budget_ms numeric, runs int default 3) returns void
language plpgsql as $$
declare t0 timestamptz; best numeric := null; d numeric;
begin
  for i in 1..runs loop
    t0 := clock_timestamp();
    execute stmt;
    d := extract(epoch from clock_timestamp() - t0) * 1000;
    best := least(coalesce(best, d), d);
  end loop;
  if best > budget_ms then raise exception 'FAIL perf %: % ms, budget % ms', label, round(best, 1), budget_ms; end if;
  raise notice 'perf %: % ms (budget % ms)', label, round(best, 1), budget_ms;
  raise notice 'ok  perf %', label;
end $$;
