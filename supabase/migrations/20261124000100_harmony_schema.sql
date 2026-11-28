begin;

create schema harmony_private;
revoke all on schema harmony_private from public, anon, authenticated;
grant usage on schema harmony_private to authenticated;

-- Managed by the database owner. Never writable through the application API.
create table harmony_private.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table harmony_private.admin_users enable row level security;
revoke all on harmony_private.admin_users from public, anon, authenticated;

create function harmony_private.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from harmony_private.admin_users where user_id = auth.uid());
$$;
revoke all on function harmony_private.is_admin() from public, anon, authenticated;
grant execute on function harmony_private.is_admin() to authenticated;

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  name text not null check (btrim(name) <> ''),
  email text,
  created_at timestamptz not null default now()
);

create table public.trainers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  direction text not null check (direction in ('pilates', 'beauty')),
  active boolean not null default true,
  unique (id, direction)
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  direction text not null check (direction in ('pilates', 'beauty')),
  name jsonb not null check (jsonb_typeof(name) = 'object' and name ?& array['ru', 'en', 'sr']),
  description jsonb not null default '{}'::jsonb check (jsonb_typeof(description) = 'object'),
  duration_minutes integer not null check (duration_minutes > 0),
  price_amount numeric(12, 2) not null check (price_amount >= 0 and price_amount <> 'NaN'::numeric),
  currency text not null default 'RSD' check (currency ~ '^[A-Z]{3}$'),
  active boolean not null default true,
  unique (id, direction)
);

create table public.trainer_services (
  trainer_id uuid not null,
  service_id uuid not null,
  direction text not null,
  active boolean not null default true,
  primary key (trainer_id, service_id),
  foreign key (trainer_id, direction) references public.trainers (id, direction),
  foreign key (service_id, direction) references public.services (id, direction)
);

create table public.classes (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null,
  service_id uuid not null,
  starts_at timestamptz not null check (isfinite(starts_at)),
  kind text not null check (kind in ('group', 'individual')),
  capacity integer not null check (capacity > 0 and (kind <> 'individual' or capacity = 1)),
  occupied_seats integer not null default 0 check (occupied_seats between 0 and capacity),
  status text not null default 'scheduled' check (status in ('scheduled', 'cancelled')),
  foreign key (trainer_id, service_id) references public.trainer_services (trainer_id, service_id)
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  class_id uuid not null references public.classes(id),
  status text not null check (status in ('pending', 'confirmed', 'attended', 'cancelled')),
  created_at timestamptz not null default now()
);

create unique index bookings_one_active_per_client_class
  on public.bookings (client_id, class_id) where status <> 'cancelled';
create index bookings_class_idx on public.bookings (class_id);
create index bookings_client_idx on public.bookings (client_id);
create index classes_status_start_idx on public.classes (status, starts_at);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  name text not null check (btrim(name) <> ''),
  total_sessions integer not null check (total_sessions > 0),
  remaining_sessions integer not null check (remaining_sessions between 0 and total_sessions),
  starts_on date,
  expires_on date,
  check (expires_on is null or starts_on is null or expires_on >= starts_on)
);
create index memberships_client_idx on public.memberships (client_id);

-- All booking writes, including trusted SQL imports, share this atomic counter.
create function harmony_private.sync_booking_seats()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_delta integer := 0;
  v_class_id uuid;
begin
  if tg_op <> 'INSERT' then
    v_class_id := old.class_id;
    if old.status <> 'cancelled' then v_delta := -1; end if;
  end if;
  if tg_op <> 'DELETE' then
    v_class_id := new.class_id;
    if new.status <> 'cancelled' then v_delta := v_delta + 1; end if;
  end if;
  if tg_op = 'UPDATE' then
    if new.class_id <> old.class_id or new.client_id <> old.client_id then
      raise exception 'Booking client and class are immutable' using errcode = '23514';
    end if;
    if old.status = 'cancelled' and new.status <> 'cancelled' then
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
create trigger bookings_sync_seats
after insert or update or delete on public.bookings
for each row execute function harmony_private.sync_booking_seats();

create function harmony_private.validate_class_assignment()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.kind <> old.kind and old.occupied_seats > 0 then
      raise exception 'Cannot change class format with existing bookings' using errcode = '23514';
    end if;
    if (new.trainer_id, new.service_id) = (old.trainer_id, old.service_id) then return new; end if;
  end if;
  if not exists (
    select 1 from public.trainer_services ts
    join public.trainers t on t.id = ts.trainer_id
    join public.services s on s.id = ts.service_id
    where ts.trainer_id = new.trainer_id and ts.service_id = new.service_id
      and ts.active and t.active and s.active
    for share of ts, t, s
  ) then
    raise exception 'Trainer and service must have an active assignment' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function harmony_private.validate_class_assignment() from public, anon, authenticated;
create trigger classes_validate_assignment
before insert or update of trainer_id, service_id, kind on public.classes
for each row execute function harmony_private.validate_class_assignment();

create function harmony_private.cancel_class_bookings()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.bookings where class_id = new.id and status = 'attended') then
    raise exception 'Cannot cancel a class with recorded attendance' using errcode = '23514';
  end if;
  update public.bookings set status = 'cancelled'
    where class_id = new.id and status in ('pending', 'confirmed');
  return null;
end;
$$;
revoke all on function harmony_private.cancel_class_bookings() from public, anon, authenticated;
create trigger classes_cancel_bookings
after update of status on public.classes
for each row when (old.status = 'scheduled' and new.status = 'cancelled')
execute function harmony_private.cancel_class_bookings();

create function public.create_booking(p_class_id uuid, p_client_id uuid default null)
returns public.bookings language plpgsql security definer set search_path = ''
as $$
declare
  v_admin boolean := harmony_private.is_admin();
  v_client_id uuid;
  v_class public.classes;
  v_booking public.bookings;
  v_status text := 'confirmed';
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
  if not v_admin and (v_class.kind = 'individual' or not exists (
    select 1 from public.bookings b join public.classes c on c.id = b.class_id
    where b.client_id = v_client_id and b.status = 'attended' and c.kind = 'group'
  )) then
    v_status := 'pending';
  end if;
  insert into public.bookings (client_id, class_id, status)
    values (v_client_id, p_class_id, v_status) returning * into v_booking;
  return v_booking;
end;
$$;

create function public.change_booking(p_booking_id uuid, p_action text)
returns public.bookings language plpgsql security definer set search_path = ''
as $$
declare
  v_admin boolean := harmony_private.is_admin();
  v_booking public.bookings;
  v_status text;
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
    when v_admin and p_action = 'approve' and v_booking.status = 'pending' then 'confirmed'
    when v_admin and p_action = 'attend' and v_booking.status = 'confirmed' then 'attended'
  end;
  if v_status is null then
    raise exception 'Booking transition denied' using errcode = '42501';
  end if;
  update public.bookings set status = v_status where id = p_booking_id returning * into v_booking;
  return v_booking;
end;
$$;

revoke all on function public.create_booking(uuid, uuid), public.change_booking(uuid, text)
  from public, anon, authenticated;
grant execute on function public.create_booking(uuid, uuid), public.change_booking(uuid, text)
  to authenticated;

alter table public.clients enable row level security;
alter table public.trainers enable row level security;
alter table public.services enable row level security;
alter table public.trainer_services enable row level security;
alter table public.classes enable row level security;
alter table public.bookings enable row level security;
alter table public.memberships enable row level security;

revoke all on public.clients, public.trainers, public.services, public.trainer_services,
  public.classes, public.bookings, public.memberships from public, anon, authenticated;
grant select on public.clients, public.trainers, public.services, public.trainer_services,
  public.classes, public.bookings, public.memberships to authenticated;
grant insert, update on public.clients, public.trainers, public.services, public.trainer_services,
  public.memberships to authenticated;
grant insert (trainer_id, service_id, starts_at, kind, capacity, status),
  update (trainer_id, service_id, starts_at, kind, capacity, status) on public.classes to authenticated;

create policy clients_read on public.clients for select to authenticated
  using (auth_user_id = (select auth.uid()) or (select harmony_private.is_admin()));
create policy clients_admin on public.clients for all to authenticated
  using ((select harmony_private.is_admin())) with check ((select harmony_private.is_admin()));

create policy classes_read on public.classes for select to authenticated
  using (status = 'scheduled' or (select harmony_private.is_admin()) or exists (
    select 1 from public.bookings b where b.class_id = classes.id
  ));
create policy classes_admin on public.classes for all to authenticated
  using ((select harmony_private.is_admin())) with check ((select harmony_private.is_admin()));

create policy trainers_read on public.trainers for select to authenticated
  using (active or (select harmony_private.is_admin()) or exists (
    select 1 from public.classes c where c.trainer_id = trainers.id
  ));
create policy trainers_admin on public.trainers for all to authenticated
  using ((select harmony_private.is_admin())) with check ((select harmony_private.is_admin()));
create policy services_read on public.services for select to authenticated
  using (active or (select harmony_private.is_admin()) or exists (
    select 1 from public.classes c where c.service_id = services.id
  ));
create policy services_admin on public.services for all to authenticated
  using ((select harmony_private.is_admin())) with check ((select harmony_private.is_admin()));
create policy trainer_services_read on public.trainer_services for select to authenticated
  using ((select harmony_private.is_admin()));
create policy trainer_services_admin on public.trainer_services for all to authenticated
  using ((select harmony_private.is_admin())) with check ((select harmony_private.is_admin()));

create policy bookings_read on public.bookings for select to authenticated
  using ((select harmony_private.is_admin()) or exists (
    select 1 from public.clients c where c.id = bookings.client_id and c.auth_user_id = (select auth.uid())
  ));
create policy memberships_read on public.memberships for select to authenticated
  using ((select harmony_private.is_admin()) or exists (
    select 1 from public.clients c where c.id = memberships.client_id and c.auth_user_id = (select auth.uid())
  ));
create policy memberships_admin on public.memberships for all to authenticated
  using ((select harmony_private.is_admin())) with check ((select harmony_private.is_admin()));

commit;
