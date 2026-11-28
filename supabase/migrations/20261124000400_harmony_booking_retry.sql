begin;

do $$
begin
  if to_regprocedure('harmony_private.group_membership(uuid,uuid,boolean)') is null then
    raise exception 'Apply 20261124000300_harmony_membership_booking.sql first.';
  end if;
end;
$$;

alter table public.bookings
  add column cancellation_source text,
  add constraint bookings_cancellation_source_check check (
    cancellation_source is null or
    (status = 'cancelled' and cancellation_source in ('client', 'admin', 'class'))
  );

-- Rejecting or cancelling closes only that attempt. Preserve uniqueness for live seats.
drop index if exists public.bookings_one_active_per_client_class;
create unique index bookings_one_active_per_client_class
  on public.bookings (client_id, class_id) where status in ('pending', 'confirmed', 'attended');

-- Existing cancelled bookings do not record who cancelled them. Preserve them.
create or replace function harmony_private.cancel_class_bookings()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.bookings where class_id = new.id and status = 'attended') then
    raise exception 'Cannot cancel a class with recorded attendance' using errcode = '23514';
  end if;
  update public.bookings set status = 'cancelled', cancellation_source = 'class'
    where class_id = new.id and status in ('pending', 'confirmed');
  return null;
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
  v_previous_status text;
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

  select status into v_previous_status from public.bookings
  where client_id = v_client_id and class_id = p_class_id
  order by created_at desc, id desc limit 1;

  -- Check eligibility and the remaining balance even when a retry needs approval.
  v_membership_id := harmony_private.group_membership(v_client_id, p_class_id);
  if v_previous_status = 'rejected' then v_membership_id := null; end if;
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
  update public.bookings set status = v_status, membership_id = v_membership_id,
    cancellation_source = case when v_status = 'cancelled' then
      case when v_admin then 'admin' else 'client' end
    end
    where id = p_booking_id returning * into v_booking;
  return v_booking;
end;
$$;

-- Reconcile stale seat counters without changing bookings or membership balances.
with occupancy as (
  select c.id, count(b.id)::integer as seats
  from public.classes c
  left join public.bookings b on b.class_id = c.id and b.status in ('pending', 'confirmed', 'attended')
  group by c.id
)
update public.classes c set occupied_seats = occupancy.seats
from occupancy where c.id = occupancy.id and c.occupied_seats is distinct from occupancy.seats;

notify pgrst, 'reload schema';
commit;
