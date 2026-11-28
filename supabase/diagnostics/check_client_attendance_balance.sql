-- Read-only. Paste the whole query into Supabase SQL Editor.
-- Replace the profile UUID if the test account is linked to a different profile.
with settings as (
  select '10000000-0000-4000-8000-000000000001'::uuid as client_id,
         statement_timestamp() as checked_at
), target as (
  select c.id, c.name, c.auth_user_id
  from public.clients c join settings x on x.client_id = c.id
), live_functions as (
  select x.name, p.oid is not null as installed, coalesce(pg_get_functiondef(p.oid), '') as definition
  from (values
    ('change_booking', 'public.change_booking(uuid,text)'),
    ('membership_trigger', 'harmony_private.sync_membership_reservation()'),
    ('studio_snapshot', 'public.load_studio_snapshot(boolean)'),
    ('refund_booking', 'public.refund_studio_booking(uuid,text)')
  ) x(name, signature)
  left join pg_catalog.pg_proc p on p.oid = to_regprocedure(x.signature)
), membership_rows as (
  select m.id, m.name, m.total_sessions, m.remaining_sessions, m.starts_on, m.expires_on,
         to_jsonb(m) ->> 'direction' as direction,
         (to_jsonb(m) ->> 'reserved_sessions')::integer as reserved_sessions
  from public.memberships m join target t on t.id = m.client_id
), booking_rows as (
  select b.id, b.status, b.created_at as booking_created_at,
         (to_jsonb(b) ->> 'membership_id')::uuid as membership_id,
         to_jsonb(b) ->> 'cancellation_source' as cancellation_source,
         (to_jsonb(b) ->> 'membership_charged')::boolean as membership_charged,
         to_jsonb(b) ->> 'refunded_at' as refunded_at,
         c.id as class_id, c.status as class_status, c.kind, c.starts_at,
         c.starts_at at time zone 'Europe/Belgrade' as starts_at_belgrade,
         s.name ->> 'ru' as service,
         b.status = 'attended' and c.starts_at > x.checked_at as attended_class_is_future,
         b.status = 'confirmed' and (to_jsonb(b) ->> 'membership_id') is not null as expected_to_hold_reserve
  from public.bookings b
  join target t on t.id = b.client_id
  join public.classes c on c.id = b.class_id
  join public.services s on s.id = c.service_id
  cross join settings x
), counters as (
  select m.*,
         count(b.id) filter (where b.expected_to_hold_reserve)::integer as expected_reserved,
         count(b.id) filter (where b.status = 'attended')::integer as linked_attended,
         count(b.id) filter (where b.attended_class_is_future)::integer as future_attended,
         count(b.id) filter (where b.membership_charged and b.refunded_at is null)::integer as marked_charged_without_refund
  from membership_rows m left join booking_rows b on b.membership_id = m.id
  group by m.id, m.name, m.total_sessions, m.remaining_sessions, m.starts_on, m.expires_on, m.direction, m.reserved_sessions
)
select jsonb_build_object(
  'checked_at', x.checked_at,
  'checked_at_belgrade', x.checked_at at time zone 'Europe/Belgrade',
  'client', (select to_jsonb(t) from target t),
  'live_schema', jsonb_build_object(
    'attendance_blocks_before_start', (select position('HF005' in definition) > 0 from live_functions where name = 'change_booking'),
    'membership_trigger_debits_attendance', (select position('remaining_sessions - 1' in definition) > 0
       or position('remaining_sessions - case when consume' in definition) > 0 from live_functions where name = 'membership_trigger'),
    'membership_trigger_enabled', (select tg.tgenabled::text
       from pg_catalog.pg_trigger tg where tg.tgrelid = 'public.bookings'::regclass
         and tg.tgname = 'bookings_update_membership_reservation'),
    'membership_trigger_is_before', (select (tg.tgtype::integer & 2) <> 0
       from pg_catalog.pg_trigger tg where tg.tgrelid = 'public.bookings'::regclass
         and tg.tgname = 'bookings_update_membership_reservation'),
    'snapshot_rpc_installed', (select installed from live_functions where name = 'studio_snapshot'),
    'snapshot_includes_cancellation_settings', (select position('free_cancellation_hours' in definition) > 0
       from live_functions where name = 'studio_snapshot'),
    'refund_rpc_installed', (select installed from live_functions where name = 'refund_booking'),
    'settings_table_installed', to_regclass('public.studio_settings') is not null,
    'migration_history_table_exists', to_regclass('supabase_migrations.schema_migrations') is not null
  ),
  'memberships', coalesce((
    select jsonb_agg(to_jsonb(m) || jsonb_build_object(
      'available_from_stored_values', m.remaining_sessions - m.reserved_sessions,
      'available_displayed_by_current_app', case
        when m.direction is not null and (m.expires_on is null or m.expires_on >= (x.checked_at at time zone 'Europe/Belgrade')::date)
        then m.remaining_sessions - m.reserved_sessions else 0 end,
      'reserve_excess', m.reserved_sessions - m.expected_reserved,
      'matches_legacy_attended_holds', m.linked_attended > 0 and m.reserved_sessions = m.expected_reserved + m.linked_attended
    ) order by m.id) from counters m
  ), '[]'::jsonb),
  'bookings', coalesce((select jsonb_agg(to_jsonb(b) order by b.starts_at, b.id) from booking_rows b), '[]'::jsonb),
  'future_attended_across_studio', (select count(*) from public.bookings b join public.classes c on c.id = b.class_id
     where b.status = 'attended' and c.starts_at > x.checked_at)
) as attendance_report
from settings x;
