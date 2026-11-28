-- Read-only. Run in the SQL Editor and change the test email if needed.
with settings as (
  select 'client@example.com'::text as email, (now() at time zone 'Europe/Belgrade')::date as today
), client as (
  select c.id from public.clients c
  join auth.users u on u.id = c.auth_user_id
  join settings on lower(u.email) = lower(settings.email)
), group_classes as (
  select c.id, c.starts_at, c.capacity - c.occupied_seats as free_seats,
         (c.starts_at at time zone 'Europe/Belgrade')::date as class_date,
         s.direction, s.name ->> 'ru' as service
  from public.classes c join public.services s on s.id = c.service_id
  where c.kind = 'group' and c.status = 'scheduled'
)
select gc.id as class_id, gc.service, gc.direction, settings.today, gc.class_date, gc.free_seats,
       cl.id as client_profile_id, previous.status as latest_booking_status,
       case
         when cl.id is null then 'client_profile_missing'
         when gc.starts_at <= clock_timestamp() then 'started'
         when exists (
           select 1 from public.bookings b where b.class_id = gc.id and b.client_id = cl.id
             and b.status in ('pending', 'confirmed', 'attended')
         ) then 'already_booked'
         when gc.free_seats <= 0 then 'full'
         when passes.has_available then 'confirmed'
         when passes.has_matching then 'membership_exhausted'
         else 'pending'
       end as expected_result,
       coalesce(passes.memberships, '[]'::jsonb) as memberships
from group_classes gc cross join settings
left join client cl on true
left join lateral (
  select b.status from public.bookings b
  where b.class_id = gc.id and b.client_id = cl.id
  order by b.created_at desc, b.id desc limit 1
) previous on true
left join lateral (
  select bool_or(checks.covers_class_date) as has_matching,
         bool_or(checks.covers_class_date and m.remaining_sessions > m.reserved_sessions) as has_available,
         jsonb_agg(jsonb_build_object(
           'id', m.id, 'name', m.name, 'direction', m.direction, 'starts_on', m.starts_on,
           'expires_on', m.expires_on, 'remaining', m.remaining_sessions, 'reserved', m.reserved_sessions,
           'available', m.remaining_sessions - m.reserved_sessions,
           'covers_today', checks.covers_today, 'covers_class_date', checks.covers_class_date
         ) order by m.expires_on nulls last, m.id) as memberships
  from public.memberships m
  cross join lateral (
    select harmony_private.membership_covers_class(m.direction, m.starts_on, m.expires_on, gc.direction, settings.today) as covers_today,
           harmony_private.membership_covers_class(m.direction, m.starts_on, m.expires_on, gc.direction, gc.class_date) as covers_class_date
  ) checks
  where m.client_id = cl.id
) passes on true
order by gc.starts_at, gc.id;
