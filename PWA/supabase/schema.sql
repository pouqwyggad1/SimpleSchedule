-- SimpleSchedule PWA bootstrap schema. Run once in Supabase SQL Editor.
-- This is deliberately a bootstrap script, not a fabricated CLI migration.
begin;

create table if not exists public.pwa_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 0,
  records jsonb not null default '{}'::jsonb,
  check (jsonb_typeof(records) = 'object')
);
create table if not exists public.pwa_operations (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation_id uuid not null,
  request jsonb not null,
  result jsonb not null,
  primary key (user_id, operation_id)
);
create table if not exists public.pwa_schedule_jobs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  next_run timestamptz not null default now(),
  lease_id uuid,
  lease_until timestamptz,
  last_success timestamptz,
  last_error text
);
create table if not exists public.pwa_server_sessions (
  id text primary key check (id ~ '^[0-9a-f]{64}$'),
  payload text not null check (length(payload) < 32768),
  expires_at timestamptz not null,
  lease_id uuid,
  lease_until timestamptz
);

alter table public.pwa_state enable row level security;
alter table public.pwa_operations enable row level security;
alter table public.pwa_schedule_jobs enable row level security;
alter table public.pwa_server_sessions enable row level security;

-- No anonymous or authenticated access to encrypted server sessions.
revoke all on public.pwa_server_sessions from public, anon, authenticated;
grant all on public.pwa_server_sessions to service_role;
-- An explicit deny documents the intended closed table and satisfies the RLS advisor.
drop policy if exists no_client_access on public.pwa_server_sessions;
create policy no_client_access on public.pwa_server_sessions for all to anon, authenticated using (false) with check (false);
revoke all on public.pwa_state, public.pwa_operations, public.pwa_schedule_jobs from public, anon;
grant select, insert, update, delete on public.pwa_state, public.pwa_operations, public.pwa_schedule_jobs to authenticated, service_role;

do $$
declare t text;
begin
  foreach t in array array['pwa_state','pwa_operations','pwa_schedule_jobs'] loop
    execute format('drop policy if exists own_select on public.%I', t);
    execute format('drop policy if exists own_insert on public.%I', t);
    execute format('drop policy if exists own_update on public.%I', t);
    execute format('drop policy if exists own_delete on public.%I', t);
    execute format('create policy own_select on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t);
    execute format('create policy own_insert on public.%I for insert to authenticated with check ((select auth.uid()) = user_id)', t);
    execute format('create policy own_update on public.%I for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', t);
    execute format('create policy own_delete on public.%I for delete to authenticated using ((select auth.uid()) = user_id)', t);
  end loop;
end $$;

-- Also validate inside PostgreSQL: the public REST API must not bypass API validation.
create or replace function public.pwa_valid_data(p_kind text, p_data jsonb) returns boolean
language plpgsql immutable security invoker set search_path = '' as $$
declare allowed text[]; k text; n integer; a integer; b integer;
begin
  if jsonb_typeof(p_data) <> 'object' or length(p_data::text) > 48000 then return false; end if;
  allowed := case p_kind
    when 'task' then array['title','date','groupId','note','completed']
    when 'group' then array['name','color']
    when 'lesson' then array['date','startMinute','endMinute','subject','kind','teacher','room','subgroup','homework','sourceId','sourceGroupId','sourceBaseline','sourceCancelled']
    when 'preferences' then array['instituteId','groupId','subgroup','durationMinutes','refreshMode','refreshIntervalHours','notificationsEnabled','beforeLessonEnabled','scheduleChangesEnabled','leadMinutes','mutedSubjects','mutedDates']
    else null end;
  if allowed is null then return false; end if;
  select count(*) into n from jsonb_object_keys(p_data);
  if n > 32 then return false; end if;
  for k in select jsonb_object_keys(p_data) loop
    if not k = any(allowed) then return false; end if;
    if k not in ('sourceBaseline','sourceCancelled','mutedSubjects','mutedDates','completed','notificationsEnabled','beforeLessonEnabled','scheduleChangesEnabled','startMinute','endMinute','durationMinutes','refreshIntervalHours','leadMinutes')
      and jsonb_typeof(p_data->k) not in ('string','null') then return false; end if;
  end loop;
  if p_kind in ('task','lesson') then
    if (p_data->>'date') !~ '^\d{4}-\d{2}-\d{2}$' or (p_data->>'date') is null then return false; end if;
    perform (p_data->>'date')::date;
    if (p_data->>'date')::date not between date '0001-01-01' and date '9999-12-31' then return false; end if;
  end if;
  if p_kind = 'task' then
    return jsonb_typeof(p_data->'title')='string' and length(btrim(p_data->>'title')) between 1 and 500 and
      jsonb_typeof(p_data->'completed')='boolean' and coalesce(length(p_data->>'note'),0)<=20000 and coalesce(length(p_data->>'groupId'),0)<=200;
  elsif p_kind = 'group' then
    return jsonb_typeof(p_data->'name')='string' and length(btrim(p_data->>'name')) between 1 and 120 and (p_data->>'color') ~ '^#[0-9a-fA-F]{6}$';
  elsif p_kind = 'lesson' then
    if p_data ? 'sourceCancelled' and jsonb_typeof(p_data->'sourceCancelled') <> 'boolean' then return false; end if;
    a := (p_data->>'startMinute')::integer; b := (p_data->>'endMinute')::integer;
    return a>=0 and b>a and b<=1440 and length(btrim(p_data->>'subject')) between 1 and 500 and
      coalesce(length(p_data->>'homework'),0)<=20000 and coalesce(length(p_data->>'teacher'),0)<=500 and
      coalesce(length(p_data->>'room'),0)<=200 and coalesce(length(p_data->>'kind'),0)<=100 and
      coalesce(length(p_data->>'subgroup'),0)<=50 and coalesce(length(p_data->>'sourceId'),0)<=200;
  elsif p_kind = 'preferences' then
    if p_data ? 'durationMinutes' and (p_data->>'durationMinutes')::integer not between 1 and 360 then return false; end if;
    if p_data ? 'refreshMode' and p_data->>'refreshMode' not in ('manual','auto') then return false; end if;
    if p_data ? 'refreshIntervalHours' and (p_data->>'refreshIntervalHours')::integer not in (1,3,6) then return false; end if;
    foreach k in array array['notificationsEnabled','beforeLessonEnabled','scheduleChangesEnabled'] loop
      if p_data ? k and jsonb_typeof(p_data->k)<>'boolean' then return false; end if;
    end loop;
    if p_data ? 'leadMinutes' and (p_data->>'leadMinutes')::integer not between 1 and 1440 then return false; end if;
    foreach k in array array['mutedSubjects','mutedDates'] loop
      if p_data ? k then
        if jsonb_typeof(p_data->k)<>'array' or jsonb_array_length(p_data->k)>1000 then return false; end if;
        if exists(select 1 from jsonb_array_elements(p_data->k) v where jsonb_typeof(v)<>'string' or length(v#>>'{}')>500 or (k='mutedDates' and (v#>>'{}') !~ '^\d{4}-\d{2}-\d{2}$')) then return false; end if;
        if k='mutedDates' then perform (v#>>'{}')::date from jsonb_array_elements(p_data->k) v; end if;
      end if;
    end loop;
    return coalesce(length(p_data->>'groupId'),0)<=12 and coalesce(length(p_data->>'instituteId'),0)<=12 and coalesce(length(p_data->>'subgroup'),0)<=50;
  end if;
  return false;
exception when others then return false;
end $$;

-- Entire user snapshot and revision are serialized under the same row lock through COMMIT.
-- Invoker privileges + ownership check protect even direct RPC calls with another user's UUID.
create or replace function public.pwa_apply(p_user uuid, p_operations jsonb) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare s public.pwa_state%rowtype; op jsonb; old jsonb; data jsonb; baseline jsonb; merged jsonb;
  result jsonb; replay public.pwa_operations%rowtype; answers jsonb := '[]'::jsonb;
  fields text[]; f text; id text; kind text; target text; opid uuid; baseversion bigint;
  proposed jsonb; changed boolean; previous_preferences jsonb; current_preferences jsonb;
begin
  if p_user is null or (current_user <> 'service_role' and p_user is distinct from auth.uid()) then raise exception 'Forbidden' using errcode='42501'; end if;
  if jsonb_typeof(p_operations) <> 'array' or jsonb_array_length(p_operations) > (case when current_user='service_role' then 1000 else 100 end) then raise exception 'Invalid operations'; end if;
  insert into public.pwa_state(user_id) values(p_user) on conflict do nothing;
  select * into strict s from public.pwa_state where user_id=p_user for update;
  previous_preferences := s.records->'preferences';
  for op in select value from jsonb_array_elements(p_operations) loop
    opid := (op->>'operationId')::uuid; id := op->>'entityId'; kind := op->>'kind';
    baseversion := (op->>'baseVersion')::bigint; data := op->'data'; baseline := op->'base';
    if id is null or length(id) not between 1 and 200 or kind not in ('task','group','lesson','preferences') or baseversion is null or baseversion<0 or (kind='preferences' and id<>'preferences') then raise exception 'Invalid operation'; end if;
    select * into replay from public.pwa_operations where user_id=p_user and operation_id=opid;
    if found then
      if replay.request<>op then raise exception 'Operation ID reused with different data'; end if;
      answers := answers || jsonb_build_array(replay.result); continue;
    end if;
    if data is not null and data<>'null'::jsonb and not coalesce(public.pwa_valid_data(kind,data),false) then raise exception 'Invalid record'; end if;
    old := s.records->id; fields := array[]::text[];
    if old is not null and old->>'kind'<>kind then raise exception 'Kind is immutable'; end if;
    if old is null then
      if baseversion<>0 or (data is null or data='null'::jsonb) then raise exception 'Missing record'; end if;
      merged := data;
    elsif (old->>'deleted')::boolean then
      if data is null or data='null'::jsonb then merged:=old->'data'; else fields:=array['__deleted']; end if;
    elsif data is null or data='null'::jsonb then
      merged := old->'data';
      if (old->>'version')::bigint<>baseversion then fields:=array['__deleted']; end if;
    elsif (old->>'version')::bigint=baseversion then merged:=data;
    elsif jsonb_typeof(baseline)<>'object' then fields:=array['__version'];
    else
      merged := old->'data';
      for f in select key from (select jsonb_object_keys(baseline) as key union select jsonb_object_keys(data) as key) all_keys loop
        if baseline->f is distinct from data->f then
          if old->'data'->f is distinct from baseline->f and old->'data'->f is distinct from data->f then fields:=array_append(fields,f);
          elsif data ? f then merged:=jsonb_set(merged,array[f],data->f,true);
          else merged:=merged-f; end if;
        end if;
      end loop;
    end if;
    if cardinality(fields)>0 then result:=jsonb_build_object('operationId',opid,'status','conflict','record',old,'conflictingFields',to_jsonb(fields));
    else
      if data is not null and data<>'null'::jsonb then
        if not coalesce(public.pwa_valid_data(kind,merged),false) then raise exception 'Invalid merged record'; end if;
        if kind='task' and merged->>'groupId' is not null then
          target:=merged->>'groupId';
          if s.records->target is null or s.records->target->>'kind'<>'group' then raise exception 'Unknown group'; end if;
          if (s.records->target->>'deleted')::boolean then merged:=jsonb_set(merged,'{groupId}','null'::jsonb,true); end if;
        end if;
      end if;
      changed := old is null or old->'data' is distinct from merged or coalesce((old->>'deleted')::boolean,false) is distinct from (data is null or data='null'::jsonb);
      if changed then s.revision:=s.revision+1; end if;
      proposed:=jsonb_build_object('id',id,'kind',kind,'data',merged,'version',case when changed then s.revision else (old->>'version')::bigint end,'deleted',data is null or data='null'::jsonb);
      s.records:=jsonb_set(s.records,array[id],proposed,true);
      if kind='group' and (data is null or data='null'::jsonb) then
        for target in select key from jsonb_each(s.records) where value->>'kind'='task' and not (value->>'deleted')::boolean and value->'data'->>'groupId'=id loop
          s.revision:=s.revision+1;
          s.records:=jsonb_set(s.records,array[target,'data','groupId'],'null'::jsonb,true);
          s.records:=jsonb_set(s.records,array[target,'version'],to_jsonb(s.revision),true);
        end loop;
      end if;
      result:=jsonb_build_object('operationId',opid,'status','applied','record',proposed,'conflictingFields','[]'::jsonb);
    end if;
    insert into public.pwa_operations values(p_user,opid,op,result);
    answers:=answers||jsonb_build_array(result);
  end loop;
  update public.pwa_state set records=s.records,revision=s.revision where user_id=p_user;
  current_preferences:=s.records->'preferences';
  if current_preferences is distinct from previous_preferences then
    if not coalesce((current_preferences->>'deleted')::boolean,true) and current_preferences->'data'->>'refreshMode'='auto' and current_preferences->'data'->>'groupId' ~ '^[0-9]{1,12}$' then
      insert into public.pwa_schedule_jobs(user_id,next_run) values(p_user,now()) on conflict(user_id) do update set next_run=least(public.pwa_schedule_jobs.next_run,now());
    else delete from public.pwa_schedule_jobs where user_id=p_user; end if;
  end if;
  return jsonb_build_object('records',coalesce((select jsonb_agg(value order by key) from jsonb_each(s.records)),'[]'::jsonb),'results',answers,'revision',s.revision);
end $$;

create or replace function public.pwa_sync(p_operations jsonb default '[]'::jsonb) returns jsonb
language sql security invoker set search_path = '' as $$ select public.pwa_apply(auth.uid(), p_operations); $$;

create or replace function public.pwa_session_create(p_id text,p_payload text,p_expires timestamptz) returns void
language plpgsql security invoker set search_path = '' as $$
begin
  if p_expires>now()+interval '31 days' or p_expires<now() then raise exception 'Invalid session expiry'; end if;
  delete from public.pwa_server_sessions where expires_at<now();
  insert into public.pwa_server_sessions(id,payload,expires_at) values(p_id,p_payload,p_expires);
end $$;
create or replace function public.pwa_session_claim(p_id text,p_lease uuid) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare s public.pwa_server_sessions%rowtype;
begin
  select * into s from public.pwa_server_sessions where id=p_id and expires_at>now() for update;
  if not found then return '{"missing":true}'::jsonb; end if;
  if s.lease_until>now() then return '{}'::jsonb; end if;
  update public.pwa_server_sessions set lease_id=p_lease,lease_until=now()+interval '45 seconds' where id=p_id;
  return jsonb_build_object('payload',s.payload);
end $$;
create or replace function public.pwa_session_release(p_id text,p_lease uuid,p_payload text) returns void
language sql security invoker set search_path = '' as $$
  update public.pwa_server_sessions set payload=coalesce(p_payload,payload),lease_id=null,lease_until=null where id=p_id and lease_id=p_lease;
$$;
create or replace function public.pwa_session_remove(p_id text) returns void
language sql security invoker set search_path = '' as $$ delete from public.pwa_server_sessions where id=p_id; $$;

create or replace function public.pwa_job_claim() returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare j public.pwa_schedule_jobs%rowtype; token uuid;
begin
  select * into j from public.pwa_schedule_jobs where next_run<=now() and (lease_until is null or lease_until<now()) order by next_run for update skip locked limit 1;
  if not found then return null; end if;
  token:=gen_random_uuid();
  update public.pwa_schedule_jobs set lease_id=token,lease_until=now()+interval '5 minutes' where user_id=j.user_id;
  return jsonb_build_object('userId',j.user_id,'lease',token,'records',coalesce((select jsonb_agg(value) from public.pwa_state, jsonb_each(records) where user_id=j.user_id),'[]'::jsonb));
end $$;
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

-- No implicit PUBLIC function execution. Only service role can run jobs/session RPCs.
revoke all on function public.pwa_valid_data(text,jsonb), public.pwa_apply(uuid,jsonb), public.pwa_sync(jsonb) from public, anon;
grant execute on function public.pwa_valid_data(text,jsonb), public.pwa_apply(uuid,jsonb), public.pwa_sync(jsonb) to authenticated, service_role;
revoke all on function public.pwa_session_create(text,text,timestamptz), public.pwa_session_claim(text,uuid),public.pwa_session_release(text,uuid,text),public.pwa_session_remove(text), public.pwa_job_claim(),public.pwa_job_complete(uuid,uuid,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.pwa_session_create(text,text,timestamptz), public.pwa_session_claim(text,uuid),public.pwa_session_release(text,uuid,text),public.pwa_session_remove(text), public.pwa_job_claim(),public.pwa_job_complete(uuid,uuid,text,jsonb,text) to service_role;
notify pgrst, 'reload schema';
commit;
