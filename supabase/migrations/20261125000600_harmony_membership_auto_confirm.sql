begin;

-- Membership writes go through the admin RPC so the write and confirmations
-- commit together. Keep the existing RLS policies and read grants.
revoke insert (client_id, name, total_sessions, remaining_sessions, direction, starts_on, expires_on),
       update (remaining_sessions, direction, starts_on, expires_on)
  on public.memberships from authenticated;

create function public.save_studio_membership(
  p_direction text, p_starts_on date, p_expires_on date, p_remaining integer,
  p_membership_id uuid default null, p_client_id uuid default null,
  p_name text default null, p_total integer default null
) returns public.memberships
language plpgsql security definer set search_path = ''
as $$
declare
  v_client_id uuid;
  v_class_ids uuid[];
  v_saved public.memberships;
  v_available integer;
  v_request record;
  v_today date := (now() at time zone 'Europe/Belgrade')::date;
begin
  if auth.uid() is null or not harmony_private.is_admin() then
    raise exception 'Membership access denied' using errcode = '42501';
  end if;
  if p_direction is null or p_direction not in ('pilates', 'beauty')
     or p_starts_on is null or p_expires_on is null or p_starts_on > p_expires_on
     or not isfinite(p_starts_on) or not isfinite(p_expires_on)
     or p_remaining is null or p_remaining < 0 then
    raise exception 'Invalid membership period or balance' using errcode = '23514';
  end if;

  if p_membership_id is null then
    v_client_id := p_client_id;
    if p_name is null or btrim(p_name) = '' or p_total is null or p_total < 1 or p_remaining > p_total then
      raise exception 'Invalid membership name or total' using errcode = '23514';
    end if;
  else
    select m.client_id into v_client_id from public.memberships m where m.id = p_membership_id;
  end if;

  -- Booking RPCs use the same client lock before they lock a class. Class
  -- cancellation does not need the client lock and takes the class first.
  perform 1 from public.clients where id = v_client_id for no key update;
  if not found then
    raise exception 'Client or membership not found' using errcode = '22023';
  end if;

  if p_remaining > 0 and v_today between p_starts_on and p_expires_on then
    -- Lock all candidate classes before writing the membership. Use a stable
    -- order for the locks, then process requests independently by class date.
    v_class_ids := array(
      select c.id from public.classes c join public.services s on s.id = c.service_id
      where c.kind = 'group' and c.status = 'scheduled' and c.starts_at > clock_timestamp()
        and harmony_private.membership_covers_class(p_direction, p_starts_on, p_expires_on,
          s.direction, (c.starts_at at time zone 'Europe/Belgrade')::date)
        and exists (
          select 1 from public.bookings b
          where b.class_id = c.id and b.client_id = v_client_id and b.status = 'pending'
        )
      order by c.id
      for update of c
    );
  end if;

  if p_membership_id is null then
    insert into public.memberships (client_id, name, total_sessions, remaining_sessions, direction, starts_on, expires_on)
    values (v_client_id, btrim(p_name), p_total, p_remaining, p_direction, p_starts_on, p_expires_on)
    returning * into v_saved;
  else
    update public.memberships m
    set remaining_sessions = p_remaining, direction = p_direction, starts_on = p_starts_on, expires_on = p_expires_on
    where m.id = p_membership_id and m.client_id = v_client_id
    returning * into v_saved;
    if not found then
      raise exception 'Membership not found' using errcode = '22023';
    end if;
  end if;

  v_available := v_saved.remaining_sessions - v_saved.reserved_sessions;
  if cardinality(v_class_ids) > 0 and v_available > 0 then
    for v_request in
      select b.id from public.bookings b join public.classes c on c.id = b.class_id
      where b.client_id = v_client_id and b.status = 'pending'
        and c.id = any(v_class_ids) and c.starts_at > clock_timestamp()
      order by c.starts_at, b.created_at, b.id
    loop
      exit when v_available = 0;
      -- The same booking keeps its seat. The existing trigger reserves one
      -- session on this membership as it moves from pending to confirmed.
      update public.bookings set status = 'confirmed', membership_id = v_saved.id
      where id = v_request.id and status = 'pending';
      if found then v_available := v_available - 1; end if;
    end loop;
    select * into v_saved from public.memberships where id = v_saved.id;
  end if;
  return v_saved;
end;
$$;

revoke all on function public.save_studio_membership(text,date,date,integer,uuid,uuid,text,integer)
  from public, anon, authenticated;
grant execute on function public.save_studio_membership(text,date,date,integer,uuid,uuid,text,integer)
  to authenticated;

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

  -- Serialize requests with membership changes before taking any class lock.
  perform 1 from public.clients where id = v_client_id and (v_admin or auth_user_id = auth.uid())
    for no key update;
  if not found then
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

create or replace function public.change_booking(p_booking_id uuid, p_action text)
returns public.bookings language plpgsql security definer set search_path = ''
as $$
declare
  v_admin boolean := harmony_private.is_admin();
  v_booking public.bookings;
  v_status text;
  v_membership_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Booking access denied' using errcode = '42501';
  end if;
  select b.* into v_booking
    from public.bookings b join public.clients c on c.id = b.client_id
    where b.id = p_booking_id and (v_admin or c.auth_user_id = auth.uid());
  if not found then
    raise exception 'Booking access denied' using errcode = '42501';
  end if;
  perform 1 from public.clients where id = v_booking.client_id and (v_admin or auth_user_id = auth.uid())
    for no key update;
  if not found then
    raise exception 'Booking access denied' using errcode = '42501';
  end if;
  -- After the client lock, keep the class-before-booking lock order.
  perform 1 from public.classes where id = v_booking.class_id and status = 'scheduled' for update;
  if not found then
    raise exception 'Class is unavailable' using errcode = '23514';
  end if;
  select b.* into v_booking
    from public.bookings b join public.clients c on c.id = b.client_id
    where b.id = p_booking_id and (v_admin or c.auth_user_id = auth.uid())
    for update of b;
  if not found then
    raise exception 'Booking access denied' using errcode = '42501';
  end if;
  v_status := case
    when p_action = 'cancel' and v_booking.status in ('pending', 'confirmed') then 'cancelled'
    when v_admin and p_action = 'reject' and v_booking.status = 'pending' then 'rejected'
    when v_admin and p_action = 'approve' and v_booking.status = 'pending' then 'confirmed'
    when v_admin and p_action = 'attend' and v_booking.status = 'confirmed' then 'attended'
  end;
  if v_status is null then
    raise exception 'Booking transition denied' using errcode = '42501';
  end if;
  v_membership_id := v_booking.membership_id;
  if p_action = 'approve' then
    v_membership_id := harmony_private.group_membership(v_booking.client_id, v_booking.class_id);
  end if;
  update public.bookings set status = v_status, membership_id = v_membership_id,
    cancellation_source = case when v_status = 'cancelled' then
      case when v_admin then 'admin' else 'client' end
    end
    where id = p_booking_id returning * into v_booking;
  return v_booking;
end;
$$;

notify pgrst, 'reload schema';
commit;
