-- Run this single SQL statement in the Supabase SQL Editor.
-- First run with apply_changes = false. Review the proposed changes.
-- Then switch to true and run again. Only rows with will_restore = true are written.
-- The three seeded client names are restored by UUID even if their damage is
-- not recognizable. Set restore_seed_client_names to false to keep valid edits.
-- To restore another known test field explicitly, add its key to force_fields:
-- ARRAY['memberships/60000000-0000-4000-8000-000000000001/name']::text[]
with settings as (
  select false as apply_changes, true as restore_seed_client_names, array[]::text[] as force_fields
), seed(table_name, row_id, field_name, expected_text) as (
  values
    ('clients', '10000000-0000-4000-8000-000000000001', 'name', U&'\0410\043b\0435\043a\0441\0430\043d\0434\0440\0430 \041c\043e\0440\043e\0437\043e\0432\0430'),
    ('clients', '10000000-0000-4000-8000-000000000001', 'email', U&'alexandra@example.com'),
    ('clients', '10000000-0000-4000-8000-000000000002', 'name', U&'\041c\0430\0440\0438\044f \0412\043e\043b\043a\043e\0432\0430'),
    ('clients', '10000000-0000-4000-8000-000000000002', 'email', U&'maria@example.com'),
    ('clients', '10000000-0000-4000-8000-000000000003', 'name', U&'\0415\043b\0435\043d\0430 \0421\043e\043a\043e\043b\043e\0432\0430'),
    ('clients', '10000000-0000-4000-8000-000000000003', 'email', U&'elena@example.com'),
    ('trainers', '20000000-0000-4000-8000-000000000001', 'name', U&'Anna'),
    ('trainers', '20000000-0000-4000-8000-000000000002', 'name', U&'Mila'),
    ('trainers', '20000000-0000-4000-8000-000000000003', 'name', U&'Sofia'),
    ('memberships', '60000000-0000-4000-8000-000000000001', 'name', U&'\041f\0438\043b\0430\0442\0435\0441 \00b7 8 \0437\0430\043d\044f\0442\0438\0439'),
    ('memberships', '60000000-0000-4000-8000-000000000002', 'name', U&'\041f\0438\043b\0430\0442\0435\0441 \00b7 4 \0437\0430\043d\044f\0442\0438\044f'),
    ('services', '30000000-0000-4000-8000-000000000001', 'name.ru', U&'\041f\0438\043b\0430\0442\0435\0441 \043d\0430 \0440\0435\0444\043e\0440\043c\0435\0440\0435'),
    ('services', '30000000-0000-4000-8000-000000000001', 'name.en', U&'Reformer Pilates'),
    ('services', '30000000-0000-4000-8000-000000000001', 'name.sr', U&'Pilates na reformeru'),
    ('services', '30000000-0000-4000-8000-000000000001', 'description.ru', U&'\0420\0430\0431\043e\0442\0430 \0441 \043e\0441\0430\043d\043a\043e\0439, \0431\0430\043b\0430\043d\0441\043e\043c \0438 \0433\043b\0443\0431\043e\043a\0438\043c\0438 \043c\044b\0448\0446\0430\043c\0438.'),
    ('services', '30000000-0000-4000-8000-000000000001', 'description.en', U&'Work on posture, balance and deep muscles.'),
    ('services', '30000000-0000-4000-8000-000000000001', 'description.sr', U&'Rad na dr\017eanju, ravnote\017ei i dubokim mi\0161i\0107ima.'),
    ('services', '30000000-0000-4000-8000-000000000002', 'name.ru', U&'\041f\0438\043b\0430\0442\0435\0441 \043d\0430 \043a\043e\0432\0440\0438\043a\0435'),
    ('services', '30000000-0000-4000-8000-000000000002', 'name.en', U&'Mat Pilates'),
    ('services', '30000000-0000-4000-8000-000000000002', 'name.sr', U&'Pilates na prostirci'),
    ('services', '30000000-0000-4000-8000-000000000002', 'description.ru', U&'\041c\044f\0433\043a\043e\0435 \0443\043a\0440\0435\043f\043b\0435\043d\0438\0435 \0442\0435\043b\0430 \0447\0435\0440\0435\0437 \043a\043e\043d\0442\0440\043e\043b\0438\0440\0443\0435\043c\044b\0435 \0434\0432\0438\0436\0435\043d\0438\044f.'),
    ('services', '30000000-0000-4000-8000-000000000002', 'description.en', U&'Build strength gently through controlled movement.'),
    ('services', '30000000-0000-4000-8000-000000000002', 'description.sr', U&'Ne\017eno ja\010danje tela kroz kontrolisane pokrete.'),
    ('services', '30000000-0000-4000-8000-000000000003', 'name.ru', U&'\041c\0430\0441\0441\0430\0436 \043b\0438\0446\0430'),
    ('services', '30000000-0000-4000-8000-000000000003', 'name.en', U&'Facial massage'),
    ('services', '30000000-0000-4000-8000-000000000003', 'name.sr', U&'Masa\017ea lica'),
    ('services', '30000000-0000-4000-8000-000000000003', 'description.ru', U&'\0420\0430\0441\0441\043b\0430\0431\043b\044f\044e\0449\0438\0439 \0440\0443\0447\043d\043e\0439 \0443\0445\043e\0434 \0434\043b\044f \043b\0438\0446\0430 \0438 \0448\0435\0438.'),
    ('services', '30000000-0000-4000-8000-000000000003', 'description.en', U&'Relaxing hands-on care for the face and neck.'),
    ('services', '30000000-0000-4000-8000-000000000003', 'description.sr', U&'Opu\0161taju\0107a ru\010dna nega lica i vrata.'),
    ('services', '30000000-0000-4000-8000-000000000004', 'name.ru', U&'\0423\0432\043b\0430\0436\043d\044f\044e\0449\0438\0439 \0443\0445\043e\0434'),
    ('services', '30000000-0000-4000-8000-000000000004', 'name.en', U&'Hydrating facial'),
    ('services', '30000000-0000-4000-8000-000000000004', 'name.sr', U&'Hidratantni tretman lica'),
    ('services', '30000000-0000-4000-8000-000000000004', 'description.ru', U&'\0414\0435\043b\0438\043a\0430\0442\043d\043e\0435 \043e\0447\0438\0449\0435\043d\0438\0435 \0438 \0443\0432\043b\0430\0436\043d\0435\043d\0438\0435 \043a\043e\0436\0438.'),
    ('services', '30000000-0000-4000-8000-000000000004', 'description.en', U&'Gentle cleansing and hydration.'),
    ('services', '30000000-0000-4000-8000-000000000004', 'description.sr', U&'Blago \010di\0161\0107enje i hidratacija ko\017ee.')
), observed(table_name, row_id, field_name, value) as materialized (
  select 'clients'::text as table_name, c.id::text as row_id, f.field as field_name, f.value
  from public.clients c
  cross join lateral (values ('name', to_jsonb(c.name)), ('email', to_jsonb(c.email))) f(field, value)
  union all
  select 'trainers', t.id::text, f.field, f.value
  from public.trainers t
  cross join lateral (values ('name', to_jsonb(t.name)), ('direction', to_jsonb(t.direction))) f(field, value)
  union all
  select 'services', s.id::text, f.field, f.value
  from public.services s
  cross join lateral (
    select 'name.' || key, value from jsonb_each(s.name)
    union all select 'description.' || key, value from jsonb_each(s.description)
    union all values ('direction', to_jsonb(s.direction)), ('currency', to_jsonb(s.currency))
  ) f(field, value)
  union all
  select 'trainer_services', ts.trainer_id::text || '/' || ts.service_id::text, 'direction', to_jsonb(ts.direction)
  from public.trainer_services ts
  union all
  select 'classes', c.id::text, f.field, f.value
  from public.classes c
  cross join lateral (values ('kind', to_jsonb(c.kind)), ('status', to_jsonb(c.status))) f(field, value)
  union all
  select 'bookings', b.id::text, 'status', to_jsonb(b.status)
  from public.bookings b
  union all
  select 'memberships', m.id::text, 'name', to_jsonb(m.name)
  from public.memberships m
), inspected as materialized (
  select observed.*,
         coalesce((value #>> '{}') ~ U&'[\fffd\0080-\009f]|[?][[:space:]?]*[?]|([\0420\0421][^[:space:]]){3}|([\00d0\00d1][^[:space:]]){3}', false) as damaged
  from observed
), plan as materialized (
  select seed.table_name, seed.row_id, seed.field_name,
         actual.value as old_value, seed.expected_text,
         case
           when seed.table_name = 'clients' and seed.field_name = 'name' and settings.restore_seed_client_names then true
           when concat_ws('/', seed.table_name, seed.row_id, seed.field_name) = any(settings.force_fields) then true
           when actual.damaged then true
           when seed.table_name = 'services' and (
             jsonb_typeof(actual.value) is distinct from 'string' or btrim(actual.value #>> '{}') = ''
           ) then true
           else false
         end as will_restore
  from seed
  cross join settings
  left join inspected actual using (table_name, row_id, field_name)
  where actual.value is distinct from to_jsonb(seed.expected_text)
    and exists (
      select 1 from observed present where present.table_name = seed.table_name and present.row_id = seed.row_id
    )
), patches as materialized (
  select p.table_name, p.row_id::uuid, jsonb_object_agg(p.field_name, p.expected_text) as new_values
  from plan p cross join settings
  where settings.apply_changes and p.will_restore
  group by p.table_name, p.row_id
),
updated_clients as (
  update public.clients c
  set name = coalesce(p.new_values ->> 'name', c.name),
      email = coalesce(p.new_values ->> 'email', c.email)
  from patches p
  where p.table_name = 'clients' and c.id = p.row_id
    and not exists (
      select 1 from plan old
      where old.table_name = p.table_name and old.row_id = p.row_id::text and old.will_restore
        and (case old.field_name when 'name' then to_jsonb(c.name) else to_jsonb(c.email) end) is distinct from old.old_value
    )
  returning 'clients'::text as table_name, c.id::text as row_id
),
updated_trainers as (
  update public.trainers t
  set name = p.new_values ->> 'name'
  from patches p
  where p.table_name = 'trainers' and t.id = p.row_id
    and not exists (
      select 1 from plan old
      where old.table_name = p.table_name and old.row_id = p.row_id::text and old.will_restore
        and (to_jsonb(t.name)) is distinct from old.old_value
    )
  returning 'trainers'::text as table_name, t.id::text as row_id
),
updated_memberships as (
  update public.memberships m
  set name = p.new_values ->> 'name'
  from patches p
  where p.table_name = 'memberships' and m.id = p.row_id
    and not exists (
      select 1 from plan old
      where old.table_name = p.table_name and old.row_id = p.row_id::text and old.will_restore
        and (to_jsonb(m.name)) is distinct from old.old_value
    )
  returning 'memberships'::text as table_name, m.id::text as row_id
),
updated_services as (
  update public.services s
  set name = s.name || coalesce((
        select jsonb_object_agg(split_part(key, '.', 2), value)
        from jsonb_each(p.new_values) where key like 'name.%'
      ), '{}'::jsonb),
      description = s.description || coalesce((
        select jsonb_object_agg(split_part(key, '.', 2), value)
        from jsonb_each(p.new_values) where key like 'description.%'
      ), '{}'::jsonb)
  from patches p
  where p.table_name = 'services' and s.id = p.row_id
    and not exists (
      select 1 from plan old
      where old.table_name = p.table_name and old.row_id = p.row_id::text and old.will_restore
        and (case split_part(old.field_name, '.', 1)
        when 'name' then s.name -> split_part(old.field_name, '.', 2)
        else s.description -> split_part(old.field_name, '.', 2)
      end) is distinct from old.old_value
    )
  returning 'services'::text as table_name, s.id::text as row_id
),
changed as (
  select * from updated_clients
  union all
  select * from updated_trainers
  union all
  select * from updated_memberships
  union all
  select * from updated_services
), tables(table_name) as (
  values ('clients'), ('trainers'), ('services'), ('trainer_services'),
         ('classes'), ('bookings'), ('memberships')
), audit as (
  select t.table_name, count(i.field_name) as text_fields_checked,
         count(*) filter (where i.damaged) as suspicious_fields_before
  from tables t left join inspected i using (table_name)
  group by t.table_name
)
select audit.*, plan.row_id, plan.field_name, plan.old_value #>> '{}' as before_value,
       plan.expected_text as seed_value, plan.will_restore,
       coalesce(plan.will_restore and changed.row_id is not null, false) as restored
from audit left join plan using (table_name)
left join changed on changed.table_name = plan.table_name and changed.row_id = plan.row_id
order by audit.table_name, plan.row_id, plan.field_name;
