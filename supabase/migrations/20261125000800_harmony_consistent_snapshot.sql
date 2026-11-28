begin;

-- Return one role-scoped snapshot. PostgREST's row limit cannot truncate a
-- JSON scalar, and a STABLE read uses one MVCC snapshot for all tables.
create function public.load_studio_snapshot(p_admin boolean default false)
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_client_id uuid;
begin
  if auth.uid() is null or (p_admin and not harmony_private.is_admin()) then
    raise exception 'Studio access denied' using errcode = '42501';
  end if;
  if not p_admin then
    select c.id into v_client_id from public.clients c where c.auth_user_id = auth.uid();
  end if;

  return jsonb_build_object(
    'client_id', v_client_id,
    'today', (now() at time zone 'Europe/Belgrade')::date,
    'clients', coalesce((
      select jsonb_agg(to_jsonb(item) order by name, id)
      from (select id, name, email from public.clients c where p_admin or c.id = v_client_id) item
    ), '[]'::jsonb),
    'trainers', coalesce((
      select jsonb_agg(to_jsonb(item) order by name, id)
      from (select id, name, direction, active from public.trainers t where true) item
    ), '[]'::jsonb),
    'services', coalesce((
      select jsonb_agg(to_jsonb(item) order by id)
      from (select id, direction, name, description, duration_minutes, price_amount, currency, active from public.services s where true) item
    ), '[]'::jsonb),
    'classes', coalesce((
      select jsonb_agg(to_jsonb(item) order by starts_at, id)
      from (select id, trainer_id, service_id, starts_at, kind, capacity, occupied_seats, status from public.classes c where true) item
    ), '[]'::jsonb),
    'bookings', coalesce((
      select jsonb_agg(to_jsonb(item) order by created_at desc, id desc)
      from (select id, client_id, class_id, status, cancellation_source, created_at from public.bookings b where p_admin or b.client_id = v_client_id) item
    ), '[]'::jsonb),
    'memberships', coalesce((
      select jsonb_agg(to_jsonb(item) order by id)
      from (select id, client_id, name, total_sessions, remaining_sessions, reserved_sessions, direction, starts_on, expires_on from public.memberships m where p_admin or m.client_id = v_client_id) item
    ), '[]'::jsonb),
    'assignments', coalesce((
      select jsonb_agg(to_jsonb(item) order by trainer_id, service_id)
      from (select trainer_id, service_id from public.trainer_services ts where p_admin and ts.active) item
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.load_studio_snapshot(boolean) from public, anon, authenticated;
grant execute on function public.load_studio_snapshot(boolean) to authenticated;

notify pgrst, 'reload schema';
commit;
