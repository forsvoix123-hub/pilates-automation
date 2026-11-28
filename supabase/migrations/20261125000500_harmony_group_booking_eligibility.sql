begin;

create or replace function public.create_booking(p_class_id uuid, p_client_id uuid default null)
returns public.bookings language plpgsql security definer set search_path = ''
as $$
declare
  v_admin boolean := harmony_private.is_admin();
  v_client_id uuid;
  v_class public.classes;
  v_booking public.bookings;
  v_membership_id uuid;
begin
  if auth.uid() is null or (p_client_id is not null and not v_admin) then
    raise exception 'Booking access denied' using errcode = '42501';
  end if;
  if v_admin and p_client_id is not null then
    v_client_id := p_client_id;
  else
    select id into v_client_id from public.clients where auth_user_id = auth.uid();
  end if;
  if v_client_id is null then
    raise exception 'Client profile required' using errcode = '42501';
  end if;

  select * into v_class from public.classes where id = p_class_id for update;
  if not found or v_class.status <> 'scheduled' then
    raise exception 'Class is unavailable' using errcode = '23514';
  end if;
  if exists (select 1 from public.bookings where client_id = v_client_id and class_id = p_class_id
             and status in ('pending', 'confirmed', 'attended')) then
    raise exception 'Client already has an active booking' using errcode = '23505';
  end if;
  if v_class.occupied_seats >= v_class.capacity then
    raise exception 'Class is full' using errcode = '23514';
  end if;

  -- Evaluate the client's current eligibility on every attempt.
  v_membership_id := harmony_private.group_membership(v_client_id, p_class_id);
  insert into public.bookings (client_id, class_id, status, membership_id)
    values (v_client_id, p_class_id, case when v_membership_id is null then 'pending' else 'confirmed' end,
            v_membership_id) returning * into v_booking;
  return v_booking;
end;
$$;

notify pgrst, 'reload schema';
commit;
