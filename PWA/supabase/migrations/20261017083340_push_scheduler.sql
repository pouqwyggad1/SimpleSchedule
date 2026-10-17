-- Supabase-hosted extensions. Apply after web_push_notifications.
-- Store the existing Jobs__Secret in Vault as simpleschedule_jobs_secret first.
begin;
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create function public.pwa_run_scheduled_jobs() returns bigint
language plpgsql security invoker set search_path='' as $$
declare request_id bigint; secret text;
begin
  -- No traffic when no account needs background work.
  if not exists(select 1 from public.pwa_push_subscriptions p join public.pwa_state s using(user_id)
      where s.records->'preferences'->'data'->>'notificationsEnabled'='true')
    and not exists(select 1 from public.pwa_schedule_jobs where next_run<=now()) then return null; end if;
  select decrypted_secret into secret from vault.decrypted_secrets where name='simpleschedule_jobs_secret';
  if secret is null or length(secret)<32 then return null; end if;
  select net.http_post(url:='https://simpleschedule-pwa.onrender.com/api/jobs/run',
    headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||secret),
    body:='{}'::jsonb,timeout_milliseconds:=60000) into request_id;
  return request_id;
end $$;
revoke all on function public.pwa_run_scheduled_jobs() from public,anon,authenticated,service_role;
select cron.schedule('simpleschedule-background-tick','* * * * *','select public.pwa_run_scheduled_jobs();');
-- Bounded scheduler logs; only this application's job history is affected.
select cron.schedule('simpleschedule-cron-retention','15 2 * * *',$$delete from cron.job_run_details
  where jobid in (select jobid from cron.job where jobname like 'simpleschedule-%') and end_time<now()-interval '7 days';$$);
commit;
