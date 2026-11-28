begin;

grant usage on schema harmony_private to authenticated;
revoke all on function harmony_private.is_admin() from public, anon, authenticated;
grant execute on function harmony_private.is_admin() to authenticated;

-- Return the current user's role without granting access to the allowlist.
create or replace function public.is_studio_admin()
returns boolean language sql stable security invoker set search_path = ''
as $$ select harmony_private.is_admin(); $$;
revoke all on function public.is_studio_admin() from public, anon, authenticated;
grant execute on function public.is_studio_admin() to authenticated;

-- Save the employee and their service assignments in a single transaction.
create or replace function public.save_studio_employee(
  p_id uuid, p_name text, p_direction text, p_service_ids uuid[], p_active boolean, p_editing boolean
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_direction text;
begin
  if not harmony_private.is_admin() then
    raise exception 'Employee access denied' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_service_ids), 0) = 0 or exists (
    select 1 from unnest(p_service_ids) as requested(id)
    left join public.services s on s.id = requested.id and s.direction = p_direction
    where s.id is null
  ) then
    raise exception 'Select services in the employee direction' using errcode = '23514';
  end if;
  if p_editing then
    select direction into v_direction from public.trainers where id = p_id for update;
    if not found then
      raise exception 'Employee not found' using errcode = '22023';
    end if;
    if v_direction <> p_direction then
      if exists (select 1 from public.classes where trainer_id = p_id) then
        raise exception 'Cannot change direction for an employee with class history' using errcode = '23514';
      end if;
      delete from public.trainer_services where trainer_id = p_id;
    end if;
    update public.trainers set name = btrim(p_name), direction = p_direction, active = p_active where id = p_id;
  else
    insert into public.trainers (id, name, direction, active) values (p_id, btrim(p_name), p_direction, p_active);
  end if;
  update public.trainer_services set active = false
    where trainer_id = p_id and service_id <> all(p_service_ids) and active;
  insert into public.trainer_services (trainer_id, service_id, direction)
    select p_id, id, p_direction from (select distinct unnest(p_service_ids) as id) requested
    on conflict (trainer_id, service_id) do update set active = true;
end;
$$;
revoke all on function public.save_studio_employee(uuid, text, text, uuid[], boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.save_studio_employee(uuid, text, text, uuid[], boolean, boolean) to authenticated;

notify pgrst, 'reload schema';

commit;
