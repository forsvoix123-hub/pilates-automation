-- Run as the project owner in Supabase SQL Editor.
-- The two email/password accounts must already exist in Authentication > Users.
begin;

do $$
declare
  admin_user uuid;
  client_user uuid;
  seeded_profile constant uuid := '10000000-0000-4000-8000-000000000001';
  current_owner uuid;
begin
  if to_regprocedure('public.is_studio_admin()') is null then
    raise exception 'Run the Harmony app access migration before assigning the test roles.';
  end if;

  select id into strict admin_user from auth.users where lower(email) = 'admin@example.com';
  select id into strict client_user from auth.users where lower(email) = 'client@example.com';

  if exists (
    select 1 from auth.users where id in (admin_user, client_user) and email_confirmed_at is null
  ) then
    raise exception 'Confirm both test account emails in Supabase Auth before assigning roles.';
  end if;

  select auth_user_id into strict current_owner
  from public.clients where id = seeded_profile for update;

  if current_owner is not null and current_owner not in (admin_user, client_user) then
    raise exception 'The seeded client profile belongs to a different account. No changes applied.';
  end if;
  if exists (
    select 1 from public.clients where auth_user_id = client_user and id <> seeded_profile
  ) then
    raise exception 'client@example.com already has a different client profile. No changes applied.';
  end if;

  update public.clients set auth_user_id = client_user
  where id = seeded_profile and auth_user_id is distinct from client_user;

  delete from harmony_private.admin_users where user_id = client_user;
  insert into harmony_private.admin_users (user_id) values (admin_user)
  on conflict (user_id) do nothing;
exception
  when no_data_found then
    raise exception 'A test Auth account or the seeded client profile is missing. No changes applied.';
  when too_many_rows then
    raise exception 'A test email matches multiple Auth accounts. No changes applied.';
end;
$$;

select u.email,
       exists (select 1 from harmony_private.admin_users a where a.user_id = u.id) as crm_access,
       c.id as linked_client_profile
from auth.users u
left join public.clients c on c.auth_user_id = u.id
where lower(u.email) in ('admin@example.com', 'client@example.com')
order by u.email;

commit;
