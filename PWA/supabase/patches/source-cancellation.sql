-- Existing installations only. Fresh installations already include this function in schema.sql.
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
notify pgrst, 'reload schema';
