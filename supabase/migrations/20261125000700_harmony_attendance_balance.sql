begin;

lock table public.bookings, public.memberships in share row exclusive mode nowait;

-- Previously both confirmed and attended bookings held a reservation.
-- Settle only attendance still represented in those counters, once. The
-- available balance (remaining minus reserved) is unchanged by settlement.
do $$
declare
  item record;
begin
  for item in
    select m.id, m.reserved_sessions,
      count(*) filter (where b.status = 'confirmed')::integer as confirmed,
      count(*) filter (where b.status = 'attended')::integer as attended
    from public.memberships m left join public.bookings b on b.membership_id = m.id
    group by m.id, m.reserved_sessions
  loop
    if item.reserved_sessions not in (item.confirmed, item.confirmed + item.attended) then
      raise exception 'Membership % has an inconsistent reservation counter', item.id using errcode = '23514';
    end if;
    if item.attended > 0 and item.reserved_sessions = item.confirmed + item.attended then
      update public.memberships
      set reserved_sessions = reserved_sessions - item.attended,
          remaining_sessions = remaining_sessions - item.attended
      where id = item.id;
    end if;
  end loop;
end;
$$;

create or replace function harmony_private.sync_membership_reservation()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  previous_id uuid;
  next_id uuid;
begin
  if tg_op = 'UPDATE' then
    if old.membership_id is not null and new.membership_id is distinct from old.membership_id then
      raise exception 'Membership assignment is immutable after reservation' using errcode = '23514';
    end if;
    if old.status = 'attended' and
       (new.status <> 'attended' or new.membership_id is distinct from old.membership_id) then
      raise exception 'Recorded attendance cannot be reassigned or reversed' using errcode = '23514';
    end if;
  end if;

  if tg_op <> 'DELETE' and new.status = 'attended' and new.membership_id is not null then
    if tg_op = 'INSERT' then
      raise exception 'Confirm a membership booking before recording attendance' using errcode = '23514';
    end if;
    if old.status = 'attended' then return null; end if;
    if old.status <> 'confirmed' or old.membership_id is distinct from new.membership_id then
      raise exception 'Attendance requires a confirmed membership booking' using errcode = '23514';
    end if;

    update public.memberships
    set reserved_sessions = reserved_sessions - 1, remaining_sessions = remaining_sessions - 1
    where id = new.membership_id and reserved_sessions > 0 and remaining_sessions > 0;
    if not found then
      raise exception 'Missing membership reservation for attendance' using errcode = '23514';
    end if;
    return null;
  end if;

  if tg_op <> 'INSERT' and old.status = 'confirmed' then previous_id := old.membership_id; end if;
  if tg_op <> 'DELETE' and new.status = 'confirmed' then next_id := new.membership_id; end if;
  if previous_id is not distinct from next_id then return null; end if;

  if previous_id is not null then
    update public.memberships set reserved_sessions = reserved_sessions - 1 where id = previous_id;
  end if;
  if next_id is not null then
    update public.memberships m set reserved_sessions = m.reserved_sessions + 1
    from public.classes c join public.services s on s.id = c.service_id
    where m.id = next_id and c.id = new.class_id and c.kind = 'group' and c.status = 'scheduled'
      and m.client_id = new.client_id and m.reserved_sessions < m.remaining_sessions
      and harmony_private.membership_covers_class(m.direction, m.starts_on, m.expires_on,
        s.direction, (c.starts_at at time zone 'Europe/Belgrade')::date);
    if not found then
      raise exception 'No available membership sessions' using errcode = 'HF001';
    end if;
  end if;
  return null;
end;
$$;

create or replace function harmony_private.validate_membership_period()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null and (new.direction is null or new.starts_on is null or new.expires_on is null) then
    raise exception 'Membership requires a direction and both dates' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.bookings b
    join public.classes c on c.id = b.class_id join public.services s on s.id = c.service_id
    where b.membership_id = new.id and b.status = 'confirmed'
      and not harmony_private.membership_covers_class(new.direction, new.starts_on, new.expires_on,
        s.direction, (c.starts_at at time zone 'Europe/Belgrade')::date)
  ) then
    raise exception 'Membership period conflicts with existing reservations' using errcode = 'HF002';
  end if;
  return new;
end;
$$;

create or replace function harmony_private.validate_class_membership_reservations()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  candidate record;
begin
  if new.starts_at = old.starts_at and new.service_id = old.service_id then return new; end if;
  for candidate in
    select m.direction, m.starts_on, m.expires_on, s.direction as service_direction
    from public.bookings b join public.memberships m on m.id = b.membership_id
    cross join public.services s
    where b.class_id = old.id and b.status = 'confirmed' and s.id = new.service_id
    order by m.id for share of m
  loop
    if not harmony_private.membership_covers_class(candidate.direction, candidate.starts_on, candidate.expires_on,
       candidate.service_direction, (new.starts_at at time zone 'Europe/Belgrade')::date) then
      raise exception 'Class date or service conflicts with membership reservations' using errcode = 'HF002';
    end if;
  end loop;
  return new;
end;
$$;


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
  if v_class.starts_at <= clock_timestamp() then
    raise exception 'Class has already started' using errcode = 'HF003';
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
