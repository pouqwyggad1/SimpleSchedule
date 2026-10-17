-- Server-only subscription capabilities and durable, idempotent delivery queue.
begin;
create table public.pwa_push_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  next_run timestamptz not null default now(), lease_id uuid, lease_until timestamptz,
  sources jsonb, check (sources is null or jsonb_typeof(sources)='object')
);
create table public.pwa_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null, session_id text not null,
  endpoint text not null unique check(length(endpoint)<=2048),
  keys jsonb not null check(jsonb_typeof(keys)='object' and length(keys::text)<300),
  updated_at timestamptz not null default now(), last_test timestamptz,
  unique(user_id,device_id)
);
create table public.pwa_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.pwa_push_subscriptions(id) on delete cascade,
  notice_key text not null check(length(notice_key)<600), notice jsonb not null,
  expires_at timestamptz not null, next_run timestamptz not null default now(),
  status text not null default 'pending' check(status in ('pending','sent','failed','cancelled')),
  attempts integer not null default 0, lease_id uuid, lease_until timestamptz,
  unique(subscription_id,notice_key)
);
create index pwa_push_accounts_due on public.pwa_push_accounts(next_run);
create index pwa_push_deliveries_due on public.pwa_push_deliveries(next_run) where status='pending';
create index pwa_push_subscriptions_session on public.pwa_push_subscriptions(session_id);
alter table public.pwa_push_accounts enable row level security;
alter table public.pwa_push_subscriptions enable row level security;
alter table public.pwa_push_deliveries enable row level security;
revoke all on public.pwa_push_accounts,public.pwa_push_subscriptions,public.pwa_push_deliveries from public,anon,authenticated;
grant all on public.pwa_push_accounts,public.pwa_push_subscriptions,public.pwa_push_deliveries to service_role;
create policy no_client_access on public.pwa_push_accounts for all to anon,authenticated using(false) with check(false);
create policy no_client_access on public.pwa_push_subscriptions for all to anon,authenticated using(false) with check(false);
create policy no_client_access on public.pwa_push_deliveries for all to anon,authenticated using(false) with check(false);

create function public.pwa_push_register(p_user uuid,p_device uuid,p_session text,p_endpoint text,p_keys jsonb) returns void
language plpgsql security invoker set search_path='' as $$
begin
  if not exists(select 1 from public.pwa_push_subscriptions where user_id=p_user and device_id=p_device)
    and (select count(*) from public.pwa_push_subscriptions where user_id=p_user)>=10 then raise exception 'Device limit'; end if;
  insert into public.pwa_push_subscriptions(user_id,device_id,session_id,endpoint,keys)
    values(p_user,p_device,p_session,p_endpoint,p_keys)
    on conflict(user_id,device_id) do update set session_id=excluded.session_id,endpoint=excluded.endpoint,keys=excluded.keys,updated_at=now();
  insert into public.pwa_push_accounts(user_id) values(p_user) on conflict do nothing;
end $$;
create function public.pwa_push_device(p_user uuid,p_device uuid,p_remove boolean default false,p_test boolean default false) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare s public.pwa_push_subscriptions%rowtype;
begin
  select * into s from public.pwa_push_subscriptions where user_id=p_user and device_id=p_device for update;
  if not found then return null; end if;
  if p_remove then delete from public.pwa_push_subscriptions where id=s.id; return null; end if;
  if p_test then
    if s.last_test>now()-interval '60 seconds' then return null; end if;
    update public.pwa_push_subscriptions set last_test=now() where id=s.id;
  end if;
  return jsonb_build_object('deviceId',s.device_id,'endpoint',s.endpoint,'keys',s.keys);
end $$;
create function public.pwa_push_remove_session(p_session text) returns void
language sql security invoker set search_path='' as $$ delete from public.pwa_push_subscriptions where session_id=p_session; $$;

create function public.pwa_push_plan_claim() returns jsonb
language plpgsql security invoker set search_path='' as $$
declare a public.pwa_push_accounts%rowtype; token uuid; s public.pwa_state%rowtype;
begin
  select * into a from public.pwa_push_accounts p where next_run<=now() and (lease_until is null or lease_until<now())
    and exists(select 1 from public.pwa_push_subscriptions sub where sub.user_id=p.user_id)
    order by next_run for update skip locked limit 1;
  if not found then return null; end if;
  token:=gen_random_uuid();
  update public.pwa_push_accounts set lease_id=token,lease_until=now()+interval '90 seconds' where user_id=a.user_id;
  select * into s from public.pwa_state where user_id=a.user_id;
  return jsonb_build_object('userId',a.user_id,'lease',token,'revision',coalesce(s.revision,0),'sources',a.sources,
    'records',coalesce((select jsonb_agg(value) from jsonb_each(coalesce(s.records,'{}'::jsonb))),'[]'::jsonb));
end $$;
create function public.pwa_push_plan_complete(p_user uuid,p_lease uuid,p_revision bigint,p_sources jsonb,p_notices jsonb) returns void
language plpgsql security invoker set search_path='' as $$
declare n jsonb; s public.pwa_state%rowtype;
begin
  -- Keep the lock order state -> planner. Do not publish an obsolete preferences snapshot.
  select * into s from public.pwa_state where user_id=p_user for update;
  perform 1 from public.pwa_push_accounts where user_id=p_user and lease_id=p_lease and lease_until>now() for update;
  if not found then return; end if;
  if coalesce(s.revision,0)<>p_revision then
    update public.pwa_push_accounts set lease_id=null,lease_until=null,next_run=now() where user_id=p_user; return;
  end if;
  if jsonb_typeof(p_notices)<>'array' or jsonb_array_length(p_notices)>1000 or jsonb_typeof(p_sources)<>'object' then raise exception 'Invalid plan'; end if;
  for n in select value from jsonb_array_elements(p_notices) loop
    if (n->>'expiresAt')::timestamptz<=now() then continue; end if;
    insert into public.pwa_push_deliveries(subscription_id,notice_key,notice,expires_at)
      select id,n->>'key',n,(n->>'expiresAt')::timestamptz from public.pwa_push_subscriptions where user_id=p_user
      on conflict(subscription_id,notice_key) do update set notice=excluded.notice,expires_at=excluded.expires_at
        where public.pwa_push_deliveries.status='pending' and public.pwa_push_deliveries.lease_until is null;
  end loop;
  update public.pwa_push_accounts set sources=p_sources,lease_id=null,lease_until=null,next_run=now()+interval '30 seconds' where user_id=p_user;
end $$;
create function public.pwa_push_delivery_claim() returns jsonb
language plpgsql security invoker set search_path='' as $$
declare d public.pwa_push_deliveries%rowtype; s public.pwa_push_subscriptions%rowtype; token uuid;
begin
  -- Finite retention, also removes old terminal jobs without logging private payloads.
  delete from public.pwa_push_deliveries where expires_at<now()-interval '7 days';
  update public.pwa_push_deliveries set status='cancelled',lease_id=null,lease_until=null where status='pending' and expires_at<=now();
  select * into d from public.pwa_push_deliveries where status='pending' and next_run<=now() and expires_at>now()
    and attempts<5 and (lease_until is null or lease_until<now()) order by next_run for update skip locked limit 1;
  if not found then return null; end if;
  select * into strict s from public.pwa_push_subscriptions where id=d.subscription_id;
  token:=gen_random_uuid();
  update public.pwa_push_deliveries set lease_id=token,lease_until=now()+interval '45 seconds',attempts=attempts+1 where id=d.id;
  return jsonb_build_object('id',d.id,'lease',token,'notice',d.notice,
    'subscription',jsonb_build_object('deviceId',s.device_id,'endpoint',s.endpoint,'keys',s.keys),
    'records',coalesce((select jsonb_agg(value) from public.pwa_state,jsonb_each(records) where user_id=s.user_id),'[]'::jsonb));
end $$;
create function public.pwa_push_delivery_complete(p_id uuid,p_lease uuid,p_status text) returns void
language plpgsql security invoker set search_path='' as $$
declare d public.pwa_push_deliveries%rowtype;
begin
  select * into d from public.pwa_push_deliveries where id=p_id and lease_id=p_lease for update;
  if not found then return; end if;
  if p_status='expired' then delete from public.pwa_push_subscriptions where id=d.subscription_id; return; end if;
  if p_status not in ('sent','retry','failed','cancelled') then raise exception 'Invalid status'; end if;
  update public.pwa_push_deliveries set status=case when p_status='retry' and attempts<5 then 'pending' when p_status='retry' then 'failed' else p_status end,
    next_run=now()+make_interval(secs=>least(300,30*(2^attempts)::integer)),lease_id=null,lease_until=null where id=p_id;
end $$;
revoke all on function public.pwa_push_register(uuid,uuid,text,text,jsonb), public.pwa_push_device(uuid,uuid,boolean,boolean),
  public.pwa_push_remove_session(text),public.pwa_push_plan_claim(),public.pwa_push_plan_complete(uuid,uuid,bigint,jsonb,jsonb),
  public.pwa_push_delivery_claim(),public.pwa_push_delivery_complete(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.pwa_push_register(uuid,uuid,text,text,jsonb), public.pwa_push_device(uuid,uuid,boolean,boolean),
  public.pwa_push_remove_session(text),public.pwa_push_plan_claim(),public.pwa_push_plan_complete(uuid,uuid,bigint,jsonb,jsonb),
  public.pwa_push_delivery_claim(),public.pwa_push_delivery_complete(uuid,uuid,text) to service_role;
notify pgrst,'reload schema';
commit;
