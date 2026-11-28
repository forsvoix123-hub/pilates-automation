-- Read-only. Run as the SQL Editor owner to inspect the schema.
select current_setting('server_encoding') as server_encoding,
       current_setting('client_encoding') as client_encoding;

select expected.table_name, c.relrowsecurity as rls_enabled
from (values
  ('public.clients'), ('public.trainers'), ('public.services'), ('public.trainer_services'),
  ('public.classes'), ('public.bookings'), ('public.memberships'), ('harmony_private.admin_users')
) as expected(table_name)
left join pg_catalog.pg_class c on c.oid = to_regclass(expected.table_name);

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_catalog.pg_policies
where (schemaname = 'public' and tablename in (
  'clients', 'trainers', 'services', 'trainer_services', 'classes', 'bookings', 'memberships'
)) or (schemaname = 'harmony_private' and tablename = 'admin_users')
order by schemaname, tablename, policyname;

select expected.signature, p.oid is not null as installed,
       p.prosecdef as security_definer,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute
from (values
  ('auth.uid()'), ('harmony_private.is_admin()'), ('public.is_studio_admin()'),
  ('public.create_booking(uuid,uuid)'), ('public.change_booking(uuid,text)'),
  ('public.save_studio_employee(uuid,text,text,uuid[],boolean,boolean)')
) as expected(signature)
left join pg_catalog.pg_proc p on p.oid = to_regprocedure(expected.signature);

select has_schema_privilege('authenticated', to_regnamespace('harmony_private'), 'USAGE')
       as authenticated_private_schema_usage;

select id, name ->> 'ru' as name_ru, description ->> 'ru' as description_ru,
       encode(convert_to(name ->> 'ru', 'UTF8'), 'hex') as name_ru_utf8_hex,
       encode(convert_to(description ->> 'ru', 'UTF8'), 'hex') as description_ru_utf8_hex
from public.services
order by id;
