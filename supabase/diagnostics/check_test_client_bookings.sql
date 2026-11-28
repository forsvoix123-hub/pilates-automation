-- Read-only. Run after booking through the client application.
select b.id as booking_id, b.status, to_jsonb(b) ->> 'cancellation_source' as cancellation_source, b.created_at,
       c.id as client_profile_id, cl.id as class_id, cl.status as class_status,
       cl.starts_at, s.name ->> 'ru' as service, cl.capacity, cl.occupied_seats,
       to_jsonb(b) ->> 'membership_id' as membership_id
from auth.users u
join public.clients c on c.auth_user_id = u.id
join public.bookings b on b.client_id = c.id
join public.classes cl on cl.id = b.class_id
join public.services s on s.id = cl.service_id
where lower(u.email) = 'client@example.com'
order by b.created_at desc, b.id
limit 10;
