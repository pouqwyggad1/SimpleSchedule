-- Apply only to an existing SimpleSchedule PWA schema.
-- CREATE OR REPLACE retains the existing owner and function ACL.
-- No tables, policies, user records or grants are changed.
begin;

create or replace function public.pwa_job_complete(p_user uuid,p_lease uuid,p_group text,p_operations jsonb,p_error text default null) returns void
language plpgsql security invoker set search_path = '' as $$
declare prefs jsonb; hours integer;
begin
  -- Lock state before jobs, matching pwa_apply lock order to avoid deadlocks.
  select records->'preferences'->'data' into prefs from public.pwa_state where user_id=p_user for update;
  perform 1 from public.pwa_schedule_jobs where user_id=p_user and lease_id=p_lease and lease_until>now() for update;
  if not found then return; end if;
  if prefs->>'refreshMode' is distinct from 'auto' or coalesce(prefs->>'groupId','') !~ '^[0-9]{1,12}$' then
    delete from public.pwa_schedule_jobs where user_id=p_user; return;
  end if;
  if prefs->>'groupId' is distinct from p_group then
    -- The account changed groups while this lease fetched the old timetable.
    -- Keep the replacement job due; the stale result must not publish or delete it.
    update public.pwa_schedule_jobs set lease_id=null,lease_until=null,next_run=least(next_run,now()) where user_id=p_user;
    return;
  end if;
  if p_error is null then perform public.pwa_apply(p_user,p_operations); end if;
  hours:=coalesce((prefs->>'refreshIntervalHours')::integer,1);
  update public.pwa_schedule_jobs set lease_id=null,lease_until=null,
    next_run=now()+case when p_error is null then make_interval(hours=>hours) else interval '15 minutes' end,
    last_success=case when p_error is null then now() else last_success end,last_error=left(p_error,200) where user_id=p_user;
end $$;

commit;
