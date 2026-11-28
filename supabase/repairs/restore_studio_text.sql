-- Preview in the Supabase SQL Editor with apply_changes = false.
-- Review before_value and proposed_value, then set apply_changes to true.
-- To explicitly restore an undetected seeded value, add the field key to force_seed_fields.
-- Example key: services/30000000-0000-4000-8000-000000000001/name.ru
begin;

create temporary table harmony_text_repair_plan (
  table_name text not null,
  row_id uuid not null,
  field_name text not null,
  before_value text,
  proposed_value text,
  resolution text not null,
  apply_changes boolean not null,
  primary key (table_name, row_id, field_name)
) on commit drop;

create function pg_temp.harmony_text_looks_damaged(value text)
returns boolean language sql immutable strict
as $$
  select value ~ U&'[\FFFD\0080-\009F]|[?][[:space:]?]*[?]|([\0420\0421][^[:space:]]){3}|([\00D0\00D1][^[:space:]]){3}';
$$;

create function pg_temp.harmony_decode_text(value text)
returns text language plpgsql strict
as $$
declare
  codec name;
  candidate text;
  decoded text;
begin
  foreach codec in array array['WIN1251', 'WIN1252', 'LATIN1']::name[] loop
    begin
      candidate := convert_from(convert_to(value, codec), 'UTF8');
    exception when character_not_in_repertoire or untranslatable_character then
      continue;
    end;
    if candidate <> value
       and candidate ~ U&'[\0410-\044F\0401\0451]'
       and not pg_temp.harmony_text_looks_damaged(candidate) then
      if decoded is not null and decoded <> candidate then return null; end if;
      decoded := candidate;
    end if;
  end loop;
  return decoded;
end;
$$;

with settings as (
  select false as apply_changes, array[]::text[] as force_seed_fields
), seed(table_name, row_id, field_name, original_value) as (
  values
    ('services', '30000000-0000-4000-8000-000000000001'::uuid, 'name.ru', U&'\041f\0438\043b\0430\0442\0435\0441 \043d\0430 \0440\0435\0444\043e\0440\043c\0435\0440\0435'),
    ('services', '30000000-0000-4000-8000-000000000001'::uuid, 'description.ru', U&'\0420\0430\0431\043e\0442\0430 \0441 \043e\0441\0430\043d\043a\043e\0439, \0431\0430\043b\0430\043d\0441\043e\043c \0438 \0433\043b\0443\0431\043e\043a\0438\043c\0438 \043c\044b\0448\0446\0430\043c\0438.'),
    ('services', '30000000-0000-4000-8000-000000000002'::uuid, 'name.ru', U&'\041f\0438\043b\0430\0442\0435\0441 \043d\0430 \043a\043e\0432\0440\0438\043a\0435'),
    ('services', '30000000-0000-4000-8000-000000000002'::uuid, 'description.ru', U&'\041c\044f\0433\043a\043e\0435 \0443\043a\0440\0435\043f\043b\0435\043d\0438\0435 \0442\0435\043b\0430 \0447\0435\0440\0435\0437 \043a\043e\043d\0442\0440\043e\043b\0438\0440\0443\0435\043c\044b\0435 \0434\0432\0438\0436\0435\043d\0438\044f.'),
    ('services', '30000000-0000-4000-8000-000000000003'::uuid, 'name.ru', U&'\041c\0430\0441\0441\0430\0436 \043b\0438\0446\0430'),
    ('services', '30000000-0000-4000-8000-000000000003'::uuid, 'description.ru', U&'\0420\0430\0441\0441\043b\0430\0431\043b\044f\044e\0449\0438\0439 \0440\0443\0447\043d\043e\0439 \0443\0445\043e\0434 \0434\043b\044f \043b\0438\0446\0430 \0438 \0448\0435\0438.'),
    ('services', '30000000-0000-4000-8000-000000000004'::uuid, 'name.ru', U&'\0423\0432\043b\0430\0436\043d\044f\044e\0449\0438\0439 \0443\0445\043e\0434'),
    ('services', '30000000-0000-4000-8000-000000000004'::uuid, 'description.ru', U&'\0414\0435\043b\0438\043a\0430\0442\043d\043e\0435 \043e\0447\0438\0449\0435\043d\0438\0435 \0438 \0443\0432\043b\0430\0436\043d\0435\043d\0438\0435 \043a\043e\0436\0438.'),
    ('clients', '10000000-0000-4000-8000-000000000001'::uuid, 'name', U&'\0410\043b\0435\043a\0441\0430\043d\0434\0440\0430 \041c\043e\0440\043e\0437\043e\0432\0430'),
    ('clients', '10000000-0000-4000-8000-000000000002'::uuid, 'name', U&'\041c\0430\0440\0438\044f \0412\043e\043b\043a\043e\0432\0430'),
    ('clients', '10000000-0000-4000-8000-000000000003'::uuid, 'name', U&'\0415\043b\0435\043d\0430 \0421\043e\043a\043e\043b\043e\0432\0430'),
    ('trainers', '20000000-0000-4000-8000-000000000001'::uuid, 'name', U&'Anna'),
    ('trainers', '20000000-0000-4000-8000-000000000002'::uuid, 'name', U&'Mila'),
    ('trainers', '20000000-0000-4000-8000-000000000003'::uuid, 'name', U&'Sofia'),
    ('memberships', '60000000-0000-4000-8000-000000000001'::uuid, 'name', U&'\041f\0438\043b\0430\0442\0435\0441 \00b7 8 \0437\0430\043d\044f\0442\0438\0439'),
    ('memberships', '60000000-0000-4000-8000-000000000002'::uuid, 'name', U&'\041f\0438\043b\0430\0442\0435\0441 \00b7 4 \0437\0430\043d\044f\0442\0438\044f')
), current_text(table_name, row_id, field_name, before_value, invalid_json_value) as (
  select 'services', id, 'name.ru', name ->> 'ru', jsonb_typeof(name -> 'ru') is distinct from 'string' from public.services
  union all
  select 'services', id, 'description.ru', description ->> 'ru', jsonb_typeof(description -> 'ru') is distinct from 'string' from public.services
  union all
  select 'clients', id, 'name', name, false from public.clients
  union all
  select 'trainers', id, 'name', name, false from public.trainers
  union all
  select 'memberships', id, 'name', name, false from public.memberships
), candidates as materialized (
  select c.*, settings.apply_changes, seed.original_value,
         seed.original_value is not null and
           concat_ws('/', c.table_name, c.row_id, c.field_name) = any(settings.force_seed_fields) as forced
  from current_text c left join seed using (table_name, row_id, field_name) cross join settings
), flagged as materialized (
  select *, case when not forced and not invalid_json_value
                 then pg_temp.harmony_decode_text(before_value) end as decoded
  from candidates
  where forced or pg_temp.harmony_text_looks_damaged(before_value)
     or (original_value is not null and (invalid_json_value or coalesce(btrim(before_value), '') = ''))
)
insert into pg_temp.harmony_text_repair_plan
select table_name, row_id, field_name, before_value, coalesce(decoded, original_value),
       case when decoded is not null then 'decoded'
            when original_value is not null then 'seed'
            else 'manual_review' end,
       apply_changes
from flagged
where invalid_json_value or before_value is distinct from coalesce(decoded, original_value)
   or (decoded is null and original_value is null);

update public.services as target
set name = jsonb_set(target.name, '{ru}', to_jsonb(plan.proposed_value))
from pg_temp.harmony_text_repair_plan as plan
where plan.apply_changes and plan.proposed_value is not null
  and plan.table_name = 'services' and plan.field_name = 'name.ru'
  and target.id = plan.row_id and (target.name ->> 'ru') is not distinct from plan.before_value;

update public.services as target
set description = jsonb_set(target.description, '{ru}', to_jsonb(plan.proposed_value))
from pg_temp.harmony_text_repair_plan as plan
where plan.apply_changes and plan.proposed_value is not null
  and plan.table_name = 'services' and plan.field_name = 'description.ru'
  and target.id = plan.row_id and (target.description ->> 'ru') is not distinct from plan.before_value;

update public.clients as target
set name = plan.proposed_value
from pg_temp.harmony_text_repair_plan as plan
where plan.apply_changes and plan.proposed_value is not null
  and plan.table_name = 'clients' and plan.field_name = 'name'
  and target.id = plan.row_id and (target.name) is not distinct from plan.before_value;

update public.trainers as target
set name = plan.proposed_value
from pg_temp.harmony_text_repair_plan as plan
where plan.apply_changes and plan.proposed_value is not null
  and plan.table_name = 'trainers' and plan.field_name = 'name'
  and target.id = plan.row_id and (target.name) is not distinct from plan.before_value;

update public.memberships as target
set name = plan.proposed_value
from pg_temp.harmony_text_repair_plan as plan
where plan.apply_changes and plan.proposed_value is not null
  and plan.table_name = 'memberships' and plan.field_name = 'name'
  and target.id = plan.row_id and (target.name) is not distinct from plan.before_value;

select * from pg_temp.harmony_text_repair_plan order by table_name, row_id, field_name;

drop function pg_temp.harmony_decode_text(text);
drop function pg_temp.harmony_text_looks_damaged(text);
commit;
