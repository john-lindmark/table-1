-- Deck finder (supabase/functions/deck-finder): an agent that finds a recent tournament decklist from a
-- plain-language request. Each search costs real money on the Claude API, so every account gets a daily
-- allowance. Only the edge function (service role) can count searches; clients never touch this table.
create table if not exists t1_private.deck_finder_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null default (now() at time zone 'utc')::date,
  searches integer not null default 0,
  primary key (user_id, day)
);

-- Counts one search for the user today; false (and nothing counted) once the day's allowance is used.
create or replace function public.deck_finder_take(p_user uuid, p_limit integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  insert into t1_private.deck_finder_usage as u (user_id, searches) values (p_user, 1)
  on conflict (user_id, day) do update set searches = u.searches + 1
    where u.searches < p_limit
  returning searches into v_n;
  return v_n is not null;
end $$;

revoke all on function public.deck_finder_take(uuid, integer) from public, anon, authenticated;
grant execute on function public.deck_finder_take(uuid, integer) to service_role;
