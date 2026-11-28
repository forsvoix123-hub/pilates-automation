-- Preview first. To apply reviewed changes, switch apply_changes from false to true.
-- Optional: add seed UUIDs to the appropriate force array for known damage
-- that the heuristic does not detect. The literals are ASCII-safe Unicode escapes.
begin;

with settings as (
  select false as apply_changes, array[]::uuid[] as force_names, array[]::uuid[] as force_descriptions
), seed(id, name_ru, description_ru) as (
  values
    ('30000000-0000-4000-8000-000000000001'::uuid,
     U&'\041F\0438\043B\0430\0442\0435\0441 \043D\0430 \0440\0435\0444\043E\0440\043C\0435\0440\0435',
     U&'\0420\0430\0431\043E\0442\0430 \0441 \043E\0441\0430\043D\043A\043E\0439, \0431\0430\043B\0430\043D\0441\043E\043C \0438 \0433\043B\0443\0431\043E\043A\0438\043C\0438 \043C\044B\0448\0446\0430\043C\0438.'),
    ('30000000-0000-4000-8000-000000000002'::uuid,
     U&'\041F\0438\043B\0430\0442\0435\0441 \043D\0430 \043A\043E\0432\0440\0438\043A\0435',
     U&'\041C\044F\0433\043A\043E\0435 \0443\043A\0440\0435\043F\043B\0435\043D\0438\0435 \0442\0435\043B\0430 \0447\0435\0440\0435\0437 \043A\043E\043D\0442\0440\043E\043B\0438\0440\0443\0435\043C\044B\0435 \0434\0432\0438\0436\0435\043D\0438\044F.'),
    ('30000000-0000-4000-8000-000000000003'::uuid,
     U&'\041C\0430\0441\0441\0430\0436 \043B\0438\0446\0430',
     U&'\0420\0430\0441\0441\043B\0430\0431\043B\044F\044E\0449\0438\0439 \0440\0443\0447\043D\043E\0439 \0443\0445\043E\0434 \0434\043B\044F \043B\0438\0446\0430 \0438 \0448\0435\0438.'),
    ('30000000-0000-4000-8000-000000000004'::uuid,
     U&'\0423\0432\043B\0430\0436\043D\044F\044E\0449\0438\0439 \0443\0445\043E\0434',
     U&'\0414\0435\043B\0438\043A\0430\0442\043D\043E\0435 \043E\0447\0438\0449\0435\043D\0438\0435 \0438 \0443\0432\043B\0430\0436\043D\0435\043D\0438\0435 \043A\043E\0436\0438.')
), review as (
  select s.id, seed.name_ru, seed.description_ru,
         s.name -> 'ru' as old_name, s.description -> 'ru' as old_description,
         (
           jsonb_typeof(s.name -> 'ru') is distinct from 'string'
           or coalesce(btrim(s.name ->> 'ru'), '') = ''
           or s.name ->> 'ru' ~ U&'[\FFFD\0080-\009F]|[?][[:space:]?]*[?]|([\0420\0421][^[:space:]]){3}|([\00D0\00D1][^[:space:]]){3}'
           or s.id = any(settings.force_names)
         ) and (s.name ->> 'ru') is distinct from seed.name_ru as fix_name,
         (
           jsonb_typeof(s.description -> 'ru') is distinct from 'string'
           or coalesce(btrim(s.description ->> 'ru'), '') = ''
           or s.description ->> 'ru' ~ U&'[\FFFD\0080-\009F]|[?][[:space:]?]*[?]|([\0420\0421][^[:space:]]){3}|([\00D0\00D1][^[:space:]]){3}'
           or s.id = any(settings.force_descriptions)
         ) and (s.description ->> 'ru') is distinct from seed.description_ru as fix_description
  from public.services s join seed using (id) cross join settings
), updated as (
  update public.services s
  set name = case when r.fix_name then jsonb_set(s.name, '{ru}', to_jsonb(r.name_ru)) else s.name end,
      description = case when r.fix_description then jsonb_set(s.description, '{ru}', to_jsonb(r.description_ru)) else s.description end
  from review r cross join settings
  where settings.apply_changes and s.id = r.id
    and (r.fix_name or r.fix_description)
    and (s.name -> 'ru') is not distinct from r.old_name
    and (s.description -> 'ru') is not distinct from r.old_description
  returning s.id
)
select r.id, case when r.fix_name then r.old_name #>> '{}' end as name_before,
       case when r.fix_name then r.name_ru end as name_after,
       case when r.fix_description then r.old_description #>> '{}' end as description_before,
       case when r.fix_description then r.description_ru end as description_after,
       updated.id is not null as applied
from review r left join updated using (id)
where r.fix_name or r.fix_description
order by r.id;

commit;
