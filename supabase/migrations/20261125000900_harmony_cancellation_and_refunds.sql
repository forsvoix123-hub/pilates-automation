begin;

create table public.studio_settings (
  singleton boolean primary key default true check (singleton),
  free_cancellation_hours integer not null default 12 check (free_cancellation_hours >= 0)
);
insert into public.studio_settings default values;
alter table public.studio_settings enable row level security;
revoke all on public.studio_settings from public, anon, authenticated;
grant select on public.studio_settings to authenticated;
grant update (free_cancellation_hours) on public.studio_settings to authenticated;
create policy settings_read on public.studio_settings for select to authenticated using (true);
create policy settings_admin_update on public.studio_settings for update to authenticated
  using ((select harmony_private.is_admin())) with check ((select harmony_private.is_admin()));

alter table public.bookings
  add column late_cancellation boolean not null default false,
  add column membership_charged boolean not null default false,
  add column refunded_at timestamptz,
  add column refund_source text,
  add column refund_reason text,
  drop constraint bookings_status_check,
  add constraint bookings_status_check check (status in ('pending','confirmed','attended','no_show','cancelled','rejected')),
  add constraint bookings_late_cancel_check check (
    not late_cancellation or (status = 'cancelled' and cancellation_source is not null and cancellation_source in ('client','admin'))
  ),
  add constraint bookings_charge_check check (
    not membership_charged or (membership_id is not null and (status in ('attended','no_show') or late_cancellation))
  ),
  add constraint bookings_refund_check check (
    (refunded_at is null and refund_source is null and refund_reason is null) or
    (refunded_at is not null and membership_charged and refund_source is not null
      and refund_source in ('admin','class') and refund_reason is not null and btrim(refund_reason) <> '')
  );

-- Migration 007 already settled these attended debits.
update public.bookings set membership_charged = true where status = 'attended' and membership_id is not null;

drop index public.bookings_one_active_per_client_class;
create unique index bookings_one_active_per_client_class
  on public.bookings(client_id, class_id) where status in ('pending','confirmed','attended','no_show');


create or replace function harmony_private.sync_booking_seats()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_delta integer := 0;
  v_class_id uuid;
begin
  if tg_op <> 'INSERT' then
    v_class_id := old.class_id;
    if old.status in ('pending', 'confirmed', 'attended', 'no_show') then v_delta := -1; end if;
  end if;
  if tg_op <> 'DELETE' then
    v_class_id := new.class_id;
    if new.status in ('pending', 'confirmed', 'attended', 'no_show') then v_delta := v_delta + 1; end if;
  end if;
  if tg_op = 'UPDATE' then
    if new.class_id <> old.class_id or new.client_id <> old.client_id then
      raise exception 'Booking client and class are immutable' using errcode = '23514';
    end if;
    if old.status in ('cancelled', 'rejected') and new.status in ('pending', 'confirmed', 'attended', 'no_show') then
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

create or replace function harmony_private.sync_membership_reservation()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  previous_id uuid;
  next_id uuid;
  consume boolean := false;
begin
  if tg_op = 'UPDATE' then
    if old.membership_id is not null and new.membership_id is distinct from old.membership_id then
      raise exception 'Membership assignment is immutable after reservation' using errcode = '23514';
    end if;
    if old.status in ('attended', 'no_show') and
       (new.status <> old.status or new.membership_id is distinct from old.membership_id) then
      raise exception 'Final attendance cannot be reassigned or reversed' using errcode = '23514';
    end if;
    if old.refunded_at is not null and (new.refunded_at,new.refund_source,new.refund_reason)
      is distinct from (old.refunded_at,old.refund_source,old.refund_reason) then
      raise exception 'Refund is already recorded' using errcode = 'HF007';
    end if;
    new.membership_charged := old.membership_charged;
    consume := old.status = 'confirmed' and old.membership_id is not null and (
      new.status in ('attended','no_show') or (new.status = 'cancelled' and new.late_cancellation)
    );
    if new.status in ('attended','no_show') and old.status <> new.status and new.membership_id is not null and not consume then
      raise exception 'Attendance requires a confirmed membership booking' using errcode = '23514';
    end if;
    if consume then new.membership_charged := true; end if;
    if old.refunded_at is null and new.refunded_at is not null then
      if not old.membership_charged then raise exception 'No membership charge to refund' using errcode = 'HF007'; end if;
      update public.memberships set remaining_sessions = remaining_sessions + 1
      where id = old.membership_id and remaining_sessions < total_sessions;
      if not found then raise exception 'Refund exceeds membership total' using errcode = 'HF008'; end if;
    end if;
  elsif tg_op = 'INSERT' then
    if new.membership_id is not null and new.status <> 'confirmed' then
      raise exception 'Confirm a membership booking before settling it' using errcode = '23514';
    end if;
    if new.membership_charged or new.refunded_at is not null then
      raise exception 'Membership charges require a booking transition' using errcode = '23514';
    end if;
  end if;

  if tg_op <> 'INSERT' and old.status = 'confirmed' then previous_id := old.membership_id; end if;
  if tg_op <> 'DELETE' and new.status = 'confirmed' then next_id := new.membership_id; end if;
  if previous_id is distinct from next_id then
    if previous_id is not null then
      update public.memberships set reserved_sessions = reserved_sessions - 1,
        remaining_sessions = remaining_sessions - case when consume then 1 else 0 end
      where id = previous_id and reserved_sessions > 0;
      if not found then raise exception 'Missing membership reservation' using errcode = '23514'; end if;
    end if;
    if next_id is not null then
      update public.memberships m set reserved_sessions = m.reserved_sessions + 1
      from public.classes c join public.services s on s.id = c.service_id
      where m.id = next_id and c.id = new.class_id and c.kind = 'group' and c.status = 'scheduled'
        and m.client_id = new.client_id and m.reserved_sessions < m.remaining_sessions
        and harmony_private.membership_covers_class(m.direction,m.starts_on,m.expires_on,
          s.direction,(c.starts_at at time zone 'Europe/Belgrade')::date);
      if not found then raise exception 'No available membership sessions' using errcode = 'HF001'; end if;
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger bookings_update_membership_reservation on public.bookings;
create trigger bookings_update_membership_reservation
before insert or update or delete on public.bookings
for each row execute function harmony_private.sync_membership_reservation();

create or replace function harmony_private.cancel_class_bookings()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  update public.bookings set status = 'cancelled', cancellation_source = 'class', late_cancellation = false
  where class_id = new.id and status in ('pending','confirmed');
  -- Keep historical attendance and cancellation statuses and add a refund entry.
  update public.bookings set refunded_at = clock_timestamp(), refund_source = 'class', refund_reason = 'Studio cancelled the class'
  where class_id = new.id and membership_charged and refunded_at is null;
  return null;
end;
$$;

create function public.refund_studio_booking(p_booking_id uuid, p_reason text)
returns public.bookings language plpgsql security definer set search_path = ''
as $$
declare
  v_booking public.bookings;
begin
  if auth.uid() is null or not harmony_private.is_admin() then
    raise exception 'Refund access denied' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Refund reason is required' using errcode = 'HF009';
  end if;
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then raise exception 'Booking not found' using errcode = 'HF007'; end if;
  perform 1 from public.clients where id = v_booking.client_id for no key update;
  perform 1 from public.classes where id = v_booking.class_id for update;
  update public.bookings set refunded_at = clock_timestamp(), refund_source = 'admin', refund_reason = btrim(p_reason)
  where id = p_booking_id and membership_charged and refunded_at is null
  returning * into v_booking;
  if not found then raise exception 'No charge or already refunded' using errcode = 'HF007'; end if;
  return v_booking;
end;
$$;
revoke all on function public.refund_studio_booking(uuid,text) from public, anon, authenticated;
grant execute on function public.refund_studio_booking(uuid,text) to authenticated;

create or replace function harmony_private.group_membership(p_client_id uuid, p_class_id uuid, p_fail_if_exhausted boolean default true)
returns uuid language plpgsql set search_path = ''
as $$
declare
  target_direction text;
  target_date date;
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
             and status in ('pending', 'confirmed', 'attended', 'no_show')) then
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
  v_start timestamptz;
  v_end timestamptz;
  v_decision_time timestamptz;
  v_free_hours integer;
  v_late boolean := false;
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
  select c.starts_at, c.starts_at + make_interval(mins => s.duration_minutes)
  into v_start, v_end
  from public.classes c join public.services s on s.id = c.service_id
  where c.id = v_booking.class_id and c.status = 'scheduled' for update of c;
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
    when v_admin and p_action = 'no-show' and v_booking.status = 'confirmed' then 'no_show'
    when v_admin and p_action = 'attend' and v_booking.status = 'confirmed' then 'attended'
  end;
  if v_status is null then
    raise exception 'Booking transition denied' using errcode = '42501';
  end if;
  v_decision_time := clock_timestamp();
  if p_action = 'approve' and v_decision_time >= v_end then
    raise exception 'Class has ended' using errcode = 'HF004';
  elsif p_action = 'attend' and v_decision_time < v_start then
    raise exception 'Class has not started' using errcode = 'HF005';
  elsif p_action = 'no-show' and v_decision_time < v_end then
    raise exception 'Class has not ended' using errcode = 'HF006';
  end if;
  if p_action = 'cancel' and v_booking.status = 'confirmed' then
    select free_cancellation_hours into strict v_free_hours from public.studio_settings where singleton;
    v_late := v_decision_time > v_start - make_interval(hours => v_free_hours);
  end if;
  v_membership_id := v_booking.membership_id;
  if p_action = 'approve' then
    v_membership_id := harmony_private.group_membership(v_booking.client_id, v_booking.class_id);
  end if;
  update public.bookings set status = v_status, membership_id = v_membership_id, late_cancellation = v_late,
    cancellation_source = case when v_status = 'cancelled' then
      case when v_admin then 'admin' else 'client' end
    end
    where id = p_booking_id returning * into v_booking;
  return v_booking;
end;
$$;

create or replace function public.save_studio_membership(
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

  if p_remaining > 0 then
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

create or replace function public.load_studio_snapshot(p_admin boolean default false)
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
    'free_cancellation_hours', (select free_cancellation_hours from public.studio_settings where singleton),
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
      from (select id, client_id, class_id, status, cancellation_source, membership_id, late_cancellation, membership_charged, refunded_at,
                   refund_source, case when p_admin then refund_reason end as refund_reason, created_at from public.bookings b where p_admin or b.client_id = v_client_id) item
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

notify pgrst, 'reload schema';
commit;
