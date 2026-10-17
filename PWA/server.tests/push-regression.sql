-- LOCAL isolated test cluster only; every fixture is rolled back.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id,email) values('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','a@example.test'),('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','b@example.test');
set local role authenticated;
set local request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$begin
  begin perform public.pwa_push_register('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','11111111-1111-1111-1111-111111111111','s','https://web.push.apple.com/fake','{}'); raise exception 'Expected RPC deny'; exception when insufficient_privilege then null; end;
  begin perform * from public.pwa_push_subscriptions; raise exception 'Expected table deny'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role service_role;
do $$
declare u uuid:='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; device uuid:='11111111-1111-1111-1111-111111111111'; p jsonb; d jsonb; count integer;
  n jsonb:=jsonb_build_object('key','before:test:2026-10-17:600','type','before','lessonId','test','signature','hash','date','2026-10-17','expiresAt',now()+interval '1 hour','title','Тест','body','Тест');
begin
  perform public.pwa_push_register(u,device,'session-a','https://web.push.apple.com/fake','{"p256dh":"TEST","auth":"TEST"}');
  perform public.pwa_push_register(u,device,'session-a','https://web.push.apple.com/fake','{"p256dh":"TEST","auth":"TEST"}');
  select count(*) into count from public.pwa_push_subscriptions where user_id=u;
  if count<>1 then raise exception 'Registration must be idempotent'; end if;
  if public.pwa_push_device('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',device) is not null then raise exception 'Device ownership bypass'; end if;
  if public.pwa_push_device(u,device,false,true) is null or public.pwa_push_device(u,device,false,true) is not null then raise exception 'Test push cooldown'; end if;
  p:=public.pwa_push_plan_claim();
  if p->>'userId'<>u::text or public.pwa_push_plan_claim() is not null then raise exception 'Planner lease'; end if;
  perform public.pwa_push_plan_complete(u,(p->>'lease')::uuid,0,'{}',jsonb_build_array(n));
  update public.pwa_push_accounts set next_run=now();
  p:=public.pwa_push_plan_claim();
  perform public.pwa_push_plan_complete(u,(p->>'lease')::uuid,0,'{}',jsonb_build_array(n));
  select count(*) into count from public.pwa_push_deliveries;
  if count<>1 then raise exception 'Delivery dedupe'; end if;
  d:=public.pwa_push_delivery_claim();
  if d is null or public.pwa_push_delivery_claim() is not null then raise exception 'Delivery lease'; end if;
  perform public.pwa_push_delivery_complete((d->>'id')::uuid,(d->>'lease')::uuid,'retry');
  if public.pwa_push_delivery_claim() is not null then raise exception 'Retry backoff'; end if;
  update public.pwa_push_deliveries set next_run=now();
  d:=public.pwa_push_delivery_claim();
  perform public.pwa_push_delivery_complete((d->>'id')::uuid,(d->>'lease')::uuid,'sent');
  update public.pwa_push_accounts set next_run=now(); p:=public.pwa_push_plan_claim();
  perform public.pwa_push_plan_complete(u,(p->>'lease')::uuid,0,'{}',jsonb_build_array(n));
  if public.pwa_push_delivery_claim() is not null then raise exception 'Sent occurrence must never repeat'; end if;
  -- Expired capability removes only its own subscription and cascades its queue.
  insert into public.pwa_push_deliveries(subscription_id,notice_key,notice,expires_at)
    select id,'new',n||'{"key":"new"}',now()+interval '1 hour' from public.pwa_push_subscriptions;
  d:=public.pwa_push_delivery_claim();
  perform public.pwa_push_delivery_complete((d->>'id')::uuid,(d->>'lease')::uuid,'expired');
  if exists(select 1 from public.pwa_push_subscriptions where user_id=u) or exists(select 1 from public.pwa_push_deliveries) then raise exception 'Expired cleanup'; end if;
  perform public.pwa_push_register(u,device,'session-a','https://web.push.apple.com/fake','{}');
  perform public.pwa_push_remove_session('unrelated');
  if public.pwa_push_device(u,device) is null then raise exception 'Unrelated logout removed device'; end if;
  perform public.pwa_push_remove_session('session-a');
  if public.pwa_push_device(u,device) is not null then raise exception 'Logout must revoke device'; end if;
end $$;
rollback;
