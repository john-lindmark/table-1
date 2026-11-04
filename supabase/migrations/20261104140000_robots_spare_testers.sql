-- Demo testers are never robots (contract/test-robots-2026-11-04.md § Testers are never robots). The store review
-- account (appreview@table-1.site) is a demo tester, and Play's pre-launch robots sign in with the App access
-- credentials on Test Lab phones, where the Android app marks whoever signs in. Marked, the sweep would delete the
-- review account a week later. Replaces t1_private.robot_quarantine and t1_private.robot_remove from
-- 20261104120000_test_robots.sql; only the tester checks are new.

-- Marks an account a robot and turns what it made into demo data. Idempotent: false when it was already marked
-- or is a demo tester.
create or replace function t1_private.robot_quarantine(p_uid uuid, p_reason text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  e record;
begin
  if exists (select 1 from t1_private.demo_testers d where d.user_id = p_uid) then return false; end if;
  insert into t1_private.robots (user_id, reason) values (p_uid, p_reason) on conflict (user_id) do nothing;
  if not found then return false; end if;

  -- demo_owner stays null: demo_remove clears profiles a tester owns, and this is the robot's own.
  update public.profiles set is_demo = true, updated_at = now() where id = p_uid and not is_demo;
  for e in
    update public.events set is_demo = true, demo_owner = p_uid, updated_at = now()
     where created_by = p_uid and not is_demo
    returning id
  loop
    insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
    values (e.id, null, 'system', 'event.robot_quarantined', 'event', e.id, jsonb_build_object('reason', p_reason));
  end loop;

  insert into public.account_audit (actor, action, target_user, after)
  values (p_uid, 'robot.marked', p_uid, jsonb_build_object('reason', p_reason));
  return true;
end $$;
revoke all on function t1_private.robot_quarantine(uuid, text) from public, anon, authenticated;

-- Removes one robot the way account deletion does (delete_account as the robot, then the auth user). Accounts with
-- an Apple sign-in are left alone: deleting those has to revoke Apple's token, which only delete-account can.
-- A demo tester (one marked before it became a tester) is never removed.
create or replace function t1_private.robot_remove(p_uid uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not t1_private.is_robot(p_uid)
     or exists (select 1 from auth.identities i where i.user_id = p_uid and i.provider = 'apple')
     or exists (select 1 from t1_private.demo_testers d where d.user_id = p_uid) then
    return false;
  end if;
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform public.delete_account();
  delete from public.live_activity_tokens where user_id = p_uid;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('request.jwt.claims', '', true);
  delete from auth.users where id = p_uid;   -- the robots row goes with it
  return true;
end $$;
revoke all on function t1_private.robot_remove(uuid) from public, anon, authenticated;
