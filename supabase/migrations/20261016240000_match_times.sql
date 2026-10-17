-- Game and match times (2026-10-16), groundwork for pace-of-play insights.
--
-- Already recorded: rounds.started_at, every life-tracker change (tracker_ops.tapped_at) and when each tracked
-- game was recorded (tracker_games.recorded_at). matches.reported_at moves with later reports, confirms and
-- organizer edits, so it can't say when a match ended.
--
-- Added:
--   matches.result_at            first time any result arrived for the match (never moves).
--   tracker_games.started_at     when the game began: the previous game's end (sideboarding included), or for
--                                game 1 the later of the round start and the tracker opening.
--   tracker_games.first_change_at  first life/counter change in the game (play has clearly begun).
--   t1_private.match_times       one row per account per played match with match and tracked-game durations.
--                                Private (no client access) until an Insights screen is designed.
-- Caveat: organizers often enter results in a batch after the fact (10 of 12 matches on 2026-10-15), so
-- result_at is an upper bound; tracked games are the accurate source.

alter table public.matches add column if not exists result_at timestamptz;
alter table public.tracker_games add column if not exists started_at timestamptz;
alter table public.tracker_games add column if not exists first_change_at timestamptz;

create or replace function t1_private.matches_result_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.result_at is null and new.reported_at is not null then
    new.result_at := new.reported_at;
  end if;
  return new;
end $$;

drop trigger if exists matches_result_at on public.matches;
create trigger matches_result_at before insert or update on public.matches
  for each row execute function t1_private.matches_result_at();

create or replace function t1_private.tracker_games_times() returns trigger
language plpgsql set search_path = '' as $$
declare
  s public.tracker_sessions;
begin
  select * into s from public.tracker_sessions where id = new.session_id;
  if new.started_at is null then
    select g.recorded_at into new.started_at from public.tracker_games g
     where g.session_id = new.session_id and g.game_no = new.game_no - 1;
    if new.started_at is null then
      select greatest(r.started_at, s.created_at) into new.started_at
        from public.matches m left join public.rounds r on r.id = m.round_id where m.id = s.match_id;
      new.started_at := coalesce(new.started_at, s.created_at);
    end if;
  end if;
  if new.first_change_at is null then
    select min(o.tapped_at) into new.first_change_at from public.tracker_ops o
     where o.session_id = new.session_id and o.game_no = new.game_no;
  end if;
  return new;
end $$;

drop trigger if exists tracker_games_times on public.tracker_games;
create trigger tracker_games_times before insert on public.tracker_games
  for each row execute function t1_private.tracker_games_times();

-- Backfill what can be known.
update public.matches set result_at = reported_at where result_at is null and reported_at is not null;
update public.tracker_games g set
  first_change_at = (select min(o.tapped_at) from public.tracker_ops o where o.session_id = g.session_id and o.game_no = g.game_no),
  started_at = coalesce(
    (select p.recorded_at from public.tracker_games p where p.session_id = g.session_id and p.game_no = g.game_no - 1),
    (select greatest(r.started_at, s.created_at) from public.tracker_sessions s
       join public.matches m on m.id = s.match_id left join public.rounds r on r.id = m.round_id
      where s.id = g.session_id))
 where g.started_at is null;

create or replace view t1_private.match_times as
select ms.user_id,
       m.event_id,
       e.format_name,
       e.is_demo,
       m.id as match_id,
       r.number as round_number,
       r.started_at as round_started_at,
       m.result_at,
       m.result_source,
       extract(epoch from (m.result_at - r.started_at))::int as match_seconds,
       t.id is not null as tracked,
       (select count(*) from public.tracker_games g where g.session_id = t.id) as tracked_games,
       (select jsonb_agg(jsonb_build_object(
                 'game_no', g.game_no,
                 'seconds', extract(epoch from (g.recorded_at - g.started_at))::int,
                 'won', case when g.is_draw then null else g.winner_side = ms.side end,
                 'changes', (select count(*) from public.tracker_ops o where o.session_id = t.id and o.game_no = g.game_no))
               order by g.game_no)
          from public.tracker_games g where g.session_id = t.id) as games
  from public.match_sides ms
  join public.matches m on m.id = ms.match_id and not m.is_bye
  join public.rounds r on r.id = m.round_id
  join public.events e on e.id = m.event_id
  left join public.tracker_sessions t on t.match_id = m.id
 where ms.user_id is not null;

revoke all on t1_private.match_times from public, anon, authenticated;
