begin;

alter table public.memberships
  add column direction text check (direction in ('pilates', 'beauty')),
  add column reserved_sessions integer not null default 0,
  add constraint memberships_finite_period check (
    (starts_on is null or isfinite(starts_on)) and (expires_on is null or isfinite(expires_on))
  ),
  add constraint memberships_reservations_within_balance check (reserved_sessions between 0 and remaining_sessions),
  add constraint memberships_id_client_unique unique (id, client_id);

-- Only the known Pilates demo plans can be classified automatically.
update public.memberships set direction = 'pilates'
where id in ('60000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002');

alter table public.bookings
  add column membership_id uuid,
  add constraint bookings_membership_owner_fk foreign key (membership_id, client_id)
    references public.memberships(id, client_id),
  add constraint bookings_membership_status_check check (membership_id is null or status not in ('pending', 'rejected')),
  drop constraint bookings_status_check,
  add constraint bookings_status_check check (status in ('pending', 'confirmed', 'attended', 'cancelled', 'rejected'));

drop index public.bookings_one_active_per_client_class;
create unique index bookings_one_active_per_client_class
  on public.bookings (client_id, class_id) where status in ('pending', 'confirmed', 'attended');
create index bookings_membership_reservations_idx on public.bookings (membership_id)
  where membership_id is not null and status in ('confirmed', 'attended');

-- Admins edit the declared balance and validity, while booking triggers alone maintain reservations.
revoke insert, update on public.memberships from public, anon, authenticated;
grant insert (client_id, name, total_sessions, remaining_sessions, direction, starts_on, expires_on),
      update (remaining_sessions, direction, starts_on, expires_on)
  on public.memberships to authenticated;

create function harmony_private.membership_covers_class(
  p_direction text, p_starts_on date, p_expires_on date, p_service_direction text, p_class_date date
) returns boolean language sql immutable set search_path = ''
as $$
  select coalesce(p_direction = p_service_direction
    and (p_starts_on is null or p_starts_on <= p_class_date)
    and (p_expires_on is null or p_expires_on >= p_class_date), false);
$$;
revoke all on function harmony_private.membership_covers_class(text,date,date,text,date) from public, anon, authenticated;

-- Locks the selected pass. Concurrent bookings for different classes cannot
-- both reserve the last available session on the same membership.
create function harmony_private.group_membership(p_client_id uuid, p_class_id uuid, p_fail_if_exhausted boolean default true)
returns uuid language plpgsql set search_path = ''
as $$
declare
  target_direction text;
  target_date date;
  today date := (now() at time zone 'Europe/Belgrade')::date;
  selected uuid;
  has_matching boolean := false;
  candidate record;
begin
  select s.direction, (c.starts_at at time zone 'Europe/Belgrade')::date
    into target_direction, target_date
  from public.classes c join public.services s on s.id = c.service_id
  where c.id = p_class_id and c.kind = 'group';
  if not found then return null; end if;

  for candidate in
    select m.id, m.reserved_sessions, m.remaining_sessions
    from public.memberships m
    where m.client_id = p_client_id
      and harmony_private.membership_covers_class(m.direction, m.starts_on, m.expires_on, target_direction, today)
      and harmony_private.membership_covers_class(m.direction, m.starts_on, m.expires_on, target_direction, target_date)
    order by m.expires_on nulls last, m.id
    for update
  loop
    has_matching := true;
    if candidate.reserved_sessions < candidate.remaining_sessions then
      selected := candidate.id;
      exit;
    end if;
  end loop;
  if selected is null and has_matching and p_fail_if_exhausted then
    raise exception 'No available membership sessions' using errcode = 'HF001';
  end if;
  return selected;
end;
$$;
revoke all on function harmony_private.group_membership(uuid,uuid,boolean) from public, anon, authenticated;



create or replace function harmony_private.sync_booking_seats()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_delta integer := 0;
  v_class_id uuid;
begin
  if tg_op <> 'INSERT' then
    v_class_id := old.class_id;
    if old.status in ('pending', 'confirmed', 'attended') then v_delta := -1; end if;
  end if;
  if tg_op <> 'DELETE' then
    v_class_id := new.class_id;
    if new.status in ('pending', 'confirmed', 'attended') then v_delta := v_delta + 1; end if;
  end if;
  if tg_op = 'UPDATE' then
    if new.class_id <> old.class_id or new.client_id <> old.client_id then
      raise exception 'Booking client and class are immutable' using errcode = '23514';
    end if;
    if old.status in ('cancelled', 'rejected') and new.status in ('pending', 'confirmed', 'attended') then
      raise exception 'Create a new booking instead of restoring a cancelled booking' using errcode = '23514';
    end if;
  end if;
  if v_delta <> 0 then
    update public.classes
    set occupied_seats = occupied_seats + v_delta
    where id = v_class_id
      and (v_delta < 0 or (status = 'scheduled' and occupied_seats < capacity));
    if not found then
      raise exception 'Class is unavailable or full' using errcode = '23514';
    end if;
  end if;
  return null;
end;
$$;
revoke all on function harmony_private.sync_booking_seats() from public, anon, authenticated;

create function harmony_private.sync_membership_reservation()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  previous_id uuid;
  next_id uuid;
begin
  if tg_op <> 'INSERT' and old.status in ('confirmed', 'attended') then previous_id := old.membership_id; end if;
  if tg_op <> 'DELETE' and new.status in ('confirmed', 'attended') then next_id := new.membership_id; end if;
  if tg_op = 'UPDATE' and old.membership_id is not null and new.membership_id is distinct from old.membership_id then
    raise exception 'Membership assignment is immutable after reservation' using errcode = '23514';
  end if;
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
revoke all on function harmony_private.sync_membership_reservation() from public, anon, authenticated;
create trigger bookings_update_membership_reservation
after insert or update or delete on public.bookings
for each row execute function harmony_private.sync_membership_reservation();

create function harmony_private.validate_membership_period()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null and (new.direction is null or new.starts_on is null or new.expires_on is null) then
    raise exception 'Membership requires a direction and both dates' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.bookings b
    join public.classes c on c.id = b.class_id join public.services s on s.id = c.service_id
    where b.membership_id = new.id and b.status in ('confirmed', 'attended')
      and not harmony_private.membership_covers_class(new.direction, new.starts_on, new.expires_on,
        s.direction, (c.starts_at at time zone 'Europe/Belgrade')::date)
  ) then
    raise exception 'Membership period conflicts with existing reservations' using errcode = 'HF002';
  end if;
  return new;
end;
$$;
revoke all on function harmony_private.validate_membership_period() from public, anon, authenticated;
create trigger memberships_validate_period before insert or update of direction, starts_on, expires_on
on public.memberships for each row execute function harmony_private.validate_membership_period();

create function harmony_private.validate_class_membership_reservations()
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
    where b.class_id = old.id and b.status in ('confirmed', 'attended') and s.id = new.service_id
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
revoke all on function harmony_private.validate_class_membership_reservations() from public, anon, authenticated;
create trigger classes_validate_membership_reservations before update of starts_at, service_id
on public.classes for each row execute function harmony_private.validate_class_membership_reservations();



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
  -- Same lock order as class cancellation: class first, then booking.
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
  update public.bookings set status = v_status, membership_id = v_membership_id
    where id = p_booking_id returning * into v_booking;
  return v_booking;
end;
$$;

-- Reserve sessions for existing upcoming confirmed group bookings where a
-- known matching pass has room. Keep the rest of the booking history intact.
do $$
declare
  legacy record;
  selected uuid;
begin
  for legacy in
    select b.id, b.client_id, b.class_id
    from public.bookings b join public.classes c on c.id = b.class_id
    where b.status = 'confirmed' and c.status = 'scheduled' and c.kind = 'group' and c.starts_at >= now()
    order by c.starts_at, b.created_at, b.id
  loop
    selected := harmony_private.group_membership(legacy.client_id, legacy.class_id, false);
    if selected is not null then update public.bookings set membership_id = selected where id = legacy.id; end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';
commit;
