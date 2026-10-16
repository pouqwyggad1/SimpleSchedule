-- Run after mock-auth.sql + ../supabase/schema.sql on an isolated local PostgreSQL cluster.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id,email) values('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','a@example.test'),('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','b@example.test');
set local role authenticated;
set local request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$
declare r jsonb; second jsonb; op jsonb; old jsonb; stale jsonb; task jsonb; lesson jsonb; count integer;
begin
  r:=public.pwa_sync('[]');
  if r->>'revision'<>'0' or jsonb_array_length(r->'records')<>0 then raise exception 'Initial snapshot'; end if;
  op:='[{"operationId":"00000000-0000-0000-0000-000000000001","entityId":"group1","kind":"group","baseVersion":0,"base":null,"data":{"name":"Учёба","color":"#123456"}}]';
  r:=public.pwa_sync(op);
  second:=public.pwa_sync(op);
  if r<>second or r->>'revision'<>'1' then raise exception 'Idempotent retry'; end if;
  begin
    perform public.pwa_sync(replace(op::text,'Учёба','OTHER')::jsonb); raise exception 'Expected reused ID rejection';
  exception when raise_exception then if sqlerrm='Expected reused ID rejection' then raise; end if; end;
  r:=public.pwa_sync('[{"operationId":"00000000-0000-0000-0000-000000000002","entityId":"task1","kind":"task","baseVersion":0,"base":null,"data":{"title":"Прочитать","date":"2026-10-13","groupId":"group1","note":"Исходная заметка","completed":false}}]');
  old:=(select value from jsonb_array_elements(r->'records') where value->>'id'='task1');
  task:=old->'data';
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000003','entityId','task1','kind','task','baseVersion',2,'base',task,'data',task||'{"completed":true}'::jsonb));
  r:=public.pwa_sync(op);
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000004','entityId','task1','kind','task','baseVersion',2,'base',task,'data',task||'{"note":"Заметка B"}'::jsonb));
  r:=public.pwa_sync(op);
  if r->'results'->0->>'status'<>'applied' or r->'results'->0->'record'->'data'->>'completed'<>'true' or r->'results'->0->'record'->'data'->>'note'<>'Заметка B' then raise exception 'Disjoint field merge'; end if;
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000005','entityId','task1','kind','task','baseVersion',2,'base',task,'data',task||'{"note":"Заметка C"}'::jsonb));
  r:=public.pwa_sync(op);
  if r->'results'->0->>'status'<>'conflict' or not (r->'results'->0->'conflictingFields' ? 'note') or r->>'revision'<>'4' then raise exception 'Same field conflict retained'; end if;
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000006','entityId','task1','kind','task','baseVersion',2,'base',task,'data',null));
  r:=public.pwa_sync(op);
  if r->'results'->0->>'status'<>'conflict' then raise exception 'Stale delete must conflict'; end if;
  r:=public.pwa_sync('[{"operationId":"00000000-0000-0000-0000-000000000007","entityId":"group1","kind":"group","baseVersion":1,"base":{"name":"Учёба","color":"#123456"},"data":null}]');
  task:=(select value from jsonb_array_elements(r->'records') where value->>'id'='task1');
  if task->'data'->'groupId'<>'null'::jsonb or (task->>'deleted')::boolean then raise exception 'Atomic group detach preserves task'; end if;
  r:=public.pwa_sync('[{"operationId":"00000000-0000-0000-0000-000000000008","entityId":"task2","kind":"task","baseVersion":0,"base":null,"data":{"title":"После удаления","date":"2026-10-13","groupId":"group1","note":"","completed":false}}]');
  if r->'results'->0->'record'->'data'->'groupId'<>'null'::jsonb then raise exception 'Concurrent task into deleted group safely detached'; end if;
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000009','entityId','task1','kind','task','baseVersion',(task->>'version')::bigint,'base',task->'data','data',null));
  r:=public.pwa_sync(op);
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000010','entityId','task1','kind','task','baseVersion',(task->>'version')::bigint,'base',task->'data','data',(task->'data')||'{"title":"Revive"}'::jsonb));
  r:=public.pwa_sync(op);
  if r->'results'->0->>'status'<>'conflict' or not (r->'results'->0->'conflictingFields' ? '__deleted') then raise exception 'Tombstone resurrection rejected'; end if;
  begin perform public.pwa_apply('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','[]'); raise exception 'Expected cross-user RPC rejection';
  exception when insufficient_privilege then null; end;
  if exists(select 1 from public.pwa_state where user_id<>'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') then raise exception 'RLS leak'; end if;
  begin update public.pwa_state set user_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; raise exception 'Expected owner reassignment rejection';
  exception when insufficient_privilege then null; end;
  if public.pwa_valid_data('task','{"title":" ","date":"2026-10-13","completed":false}') then raise exception 'Empty title accepted'; end if;
  if public.pwa_valid_data('task','{"title":"A","date":"2026-02-30","completed":false}') then raise exception 'Invalid civil date accepted'; end if;
  if public.pwa_valid_data('task','{"title":"A","date":"2026-10-13","completed":false,"user_id":"B"}') then raise exception 'Unknown field accepted'; end if;
  if public.pwa_valid_data('preferences','{"leadMinutes":0}') or public.pwa_valid_data('preferences','{"mutedDates":["2026-02-30"]}') or public.pwa_valid_data('preferences','{"notificationsEnabled":"true"}') then raise exception 'Invalid notification preference accepted'; end if;
  r:=public.pwa_sync('[{"operationId":"00000000-0000-0000-0000-000000000011","entityId":"preferences","kind":"preferences","baseVersion":0,"base":null,"data":{"instituteId":"683","groupId":"478229","subgroup":"1","durationMinutes":90,"refreshMode":"auto","refreshIntervalHours":1,"notificationsEnabled":false,"beforeLessonEnabled":true,"scheduleChangesEnabled":true,"leadMinutes":5,"mutedSubjects":[],"mutedDates":[]}}]');
  if not exists(select 1 from public.pwa_schedule_jobs) then raise exception 'Auto preference did not create job'; end if;
  begin perform public.pwa_job_claim(); raise exception 'Expected private worker RPC rejection'; exception when insufficient_privilege then null; end;
  begin perform public.pwa_session_claim(repeat('a',64),'00000000-0000-0000-0000-000000000001'); raise exception 'Expected private session RPC rejection'; exception when insufficient_privilege then null; end;
  lesson:='{"date":"2026-10-13","startMinute":705,"endMinute":795,"subject":"Математика","kind":"лекция","teacher":"Иванов","room":"Б-100","subgroup":null,"homework":"","sourceId":"stable","sourceGroupId":"478229","sourceBaseline":{},"sourceCancelled":false}';
  if not coalesce(public.pwa_valid_data('lesson',lesson),false) or not coalesce(public.pwa_valid_data('lesson',lesson-'sourceCancelled'),false) then raise exception 'Boolean source cancellation or legacy absence rejected'; end if;
  if public.pwa_valid_data('lesson',lesson||'{"sourceCancelled":"true"}'::jsonb) or public.pwa_valid_data('lesson',lesson||'{"sourceCancelled":null}'::jsonb) then raise exception 'Invalid cancellation flag accepted'; end if;
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000012','entityId','source-lesson','kind','lesson','baseVersion',0,'base',null,'data',lesson));
  r:=public.pwa_sync(op); old:=r->'results'->0->'record';
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000013','entityId','source-lesson','kind','lesson','baseVersion',(old->>'version')::bigint,'base',old->'data','data',lesson||'{"sourceCancelled":true}'::jsonb));
  r:=public.pwa_sync(op); old:=r->'results'->0->'record';
  if (old->>'deleted')::boolean or old->'data'->>'sourceCancelled'<>'true' then raise exception 'Source cancellation created a user tombstone'; end if;
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000014','entityId','source-lesson','kind','lesson','baseVersion',(old->>'version')::bigint,'base',old->'data','data',lesson));
  r:=public.pwa_sync(op); old:=r->'results'->0->'record';
  if (old->>'deleted')::boolean or old->'data'->>'sourceCancelled'<>'false' or old->>'id'<>'source-lesson' then raise exception 'Same source ID not restored'; end if;
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000015','entityId','source-lesson','kind','lesson','baseVersion',(old->>'version')::bigint,'base',old->'data','data',null));
  r:=public.pwa_sync(op); old:=r->'results'->0->'record';
  op:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000016','entityId','source-lesson','kind','lesson','baseVersion',(old->>'version')::bigint,'base',old->'data','data',lesson));
  r:=public.pwa_sync(op);
  if r->'results'->0->>'status'<>'conflict' or not (r->'results'->0->'record'->>'deleted')::boolean then raise exception 'Explicit source deletion resurrected'; end if;
end $$;
set local request.jwt.claim.sub = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
do $$
declare r jsonb;
begin
  r:=public.pwa_sync('[]');
  if jsonb_array_length(r->'records')<>0 or r->>'revision'<>'0' then raise exception 'Account B saw account A snapshot'; end if;
  if exists(select 1 from public.pwa_operations) then raise exception 'Account B saw account A operations'; end if;
end $$;
set local role service_role;
do $$
declare job jsonb; nextjob jsonb; result jsonb; token uuid:='cccccccc-cccc-cccc-cccc-cccccccccccc';
  state_before jsonb; revision_before bigint; success_before timestamptz; prefs jsonb; operation jsonb;
begin
  job:=public.pwa_job_claim(); nextjob:=public.pwa_job_claim();
  if job is null or nextjob is not null then raise exception 'Durable job lease overlap'; end if;
  perform public.pwa_job_complete((job->>'userId')::uuid,(job->>'lease')::uuid,'478229','[]',null);
  if public.pwa_job_claim() is not null then raise exception 'Job interval not advanced'; end if;
  if not exists(select 1 from public.pwa_schedule_jobs where last_success is not null) then raise exception 'Success not committed'; end if;
  select records,revision into state_before,revision_before from public.pwa_state where user_id=(job->>'userId')::uuid;
  select last_success into success_before from public.pwa_schedule_jobs where user_id=(job->>'userId')::uuid;
  update public.pwa_schedule_jobs set next_run=now() where user_id=(job->>'userId')::uuid;
  job:=public.pwa_job_claim();
  operation:='[{"operationId":"00000000-0000-0000-0000-000000000017","entityId":"should-not-appear","kind":"task","baseVersion":0,"base":null,"data":{"title":"Do not publish after failure","date":"2026-10-13","note":"","groupId":null,"completed":false}}]';
  perform public.pwa_job_complete((job->>'userId')::uuid,(job->>'lease')::uuid,'478229',operation,'Source unavailable');
  if not exists(select 1 from public.pwa_schedule_jobs where user_id=(job->>'userId')::uuid and
    next_run=now()+interval '15 minutes' and last_error='Source unavailable' and last_success=success_before and lease_id is null and lease_until is null)
    then raise exception 'Failed automatic import did not preserve last success and schedule retry in 15 minutes'; end if;
  if exists(select 1 from public.pwa_state where user_id=(job->>'userId')::uuid and (records<>state_before or revision<>revision_before))
    then raise exception 'Failed automatic import published changes'; end if;
  if public.pwa_job_claim() is not null then raise exception 'Failed job ignored retry delay'; end if;
  update public.pwa_schedule_jobs set next_run=now() where user_id=(job->>'userId')::uuid;
  job:=public.pwa_job_claim();
  prefs:=state_before->'preferences';
  operation:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000018','entityId','preferences','kind','preferences',
    'baseVersion',(prefs->>'version')::bigint,'base',prefs->'data','data',(prefs->'data')||'{"groupId":"478240"}'::jsonb));
  perform public.pwa_apply((job->>'userId')::uuid,operation);
  select records,revision into state_before,revision_before from public.pwa_state where user_id=(job->>'userId')::uuid;
  perform public.pwa_job_complete((job->>'userId')::uuid,(job->>'lease')::uuid,'478229',
    '[{"operationId":"00000000-0000-0000-0000-000000000017","entityId":"should-not-appear","kind":"task","baseVersion":0,"base":null,"data":{"title":"Stale group must not publish","date":"2026-10-13","note":"","groupId":null,"completed":false}}]',null);
  if not exists(select 1 from public.pwa_schedule_jobs where user_id=(job->>'userId')::uuid and next_run<=now() and lease_id is null and lease_until is null)
    then raise exception 'Changing automatic group during import lost the replacement job'; end if;
  if exists(select 1 from public.pwa_state where user_id=(job->>'userId')::uuid and (records<>state_before or revision<>revision_before))
    then raise exception 'Stale automatic group published changes'; end if;
  nextjob:=public.pwa_job_claim();
  if nextjob is null or not exists(select 1 from jsonb_array_elements(nextjob->'records') r where r->>'id'='preferences' and r->'data'->>'groupId'='478240')
    then raise exception 'Replacement automatic job did not use the new group'; end if;
  perform public.pwa_job_complete((job->>'userId')::uuid,(job->>'lease')::uuid,'478229','[]',null);
  if public.pwa_job_claim() is not null then raise exception 'Stale worker released replacement lease'; end if;
  job:=nextjob;
  prefs:=state_before->'preferences';
  operation:=jsonb_build_array(jsonb_build_object('operationId','00000000-0000-0000-0000-000000000019','entityId','preferences','kind','preferences',
    'baseVersion',(prefs->>'version')::bigint,'base',prefs->'data','data',(prefs->'data')||'{"refreshMode":"manual"}'::jsonb));
  perform public.pwa_apply((job->>'userId')::uuid,operation);
  perform public.pwa_job_complete((job->>'userId')::uuid,(job->>'lease')::uuid,'478240','[]',null);
  if exists(select 1 from public.pwa_schedule_jobs where user_id=(job->>'userId')::uuid) or public.pwa_job_claim() is not null
    then raise exception 'Manual mode retained or revived an automatic job'; end if;
  perform public.pwa_session_create(repeat('a',64),'encrypted-only',now()+interval '30 days');
  result:=public.pwa_session_claim(repeat('a',64),token);
  if result->>'payload'<>'encrypted-only' then raise exception 'Session roundtrip'; end if;
  result:=public.pwa_session_claim(repeat('a',64),gen_random_uuid());
  if result<>'{}'::jsonb then raise exception 'Concurrent token rotation lease'; end if;
  perform public.pwa_session_release(repeat('a',64),token,'rotated');
  result:=public.pwa_session_claim(repeat('a',64),token);
  if result->>'payload'<>'rotated' then raise exception 'Rotated token not persisted'; end if;
  perform public.pwa_session_remove(repeat('a',64));
  result:=public.pwa_session_claim(repeat('a',64),token);
  if result->>'missing'<>'true' then raise exception 'Signout did not remove server session'; end if;
end $$;
rollback;
select 'PASS: PostgreSQL sync, RLS, idempotence, conflicts, atomic group deletion, jobs and server sessions' as result;
