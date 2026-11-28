-- SQL Editor only. Paste and run the entire file; the default is read-only.
-- Review upcoming and ended groups separately. Only put missed test visits in
-- reviewed_ended_group_ids. If a class starts while reviewing, preview again.
-- Supply individual_id only if the preview shows it belongs to this profile.
begin;

do $$
declare
  apply_changes constant boolean := false;
  profile_id constant uuid := '10000000-0000-4000-8000-000000000001';
  pass_id constant uuid := '60000000-0000-4000-8000-000000000001';
  reviewed_upcoming_group_ids constant uuid[] := array[]::uuid[];
  reviewed_ended_group_ids constant uuid[] := array[]::uuid[];
  reviewed_individual_id constant uuid := null;

  pass public.memberships;
  checked_at timestamptz;
  group_ids uuid[];
  ended_group_ids uuid[];
  individual_ids uuid[];
  cancel_ids uuid[];
  restore_ids uuid[];
  expected_reserve integer;
  selected_ids uuid[];
  linked_attended integer;
  confirmed_before integer;
  confirmed_after integer;
  changed integer := 0;
  cancelled_count integer;
  schema_ok boolean;
  preflight_ok boolean;
  selection_ok boolean;
  occupancy_expected jsonb;
  occupancy_after jsonb;
  planned_rows jsonb;
begin
  if apply_changes then
    -- Prevent a booking, schedule change or balance adjustment between the
    -- checks and the correction. Fail quickly if another write is in progress.
    lock table public.classes, public.bookings, public.memberships, public.services in share row exclusive mode nowait;
  end if;
  checked_at := clock_timestamp();

  select m.* into pass from public.memberships m where m.id = pass_id and m.client_id = profile_id;
  select count(*) filter (where b.status = 'attended'), count(*) filter (where b.status = 'confirmed')
  into linked_attended, confirmed_before
  from public.bookings b where b.membership_id = pass_id and b.client_id = profile_id;

  select coalesce(array_agg(b.id order by b.id) filter (where c.starts_at > checked_at
           and harmony_private.membership_covers_class(pass.direction, pass.starts_on, pass.expires_on,
             s.direction, (c.starts_at at time zone 'Europe/Belgrade')::date)), array[]::uuid[]),
         coalesce(array_agg(b.id order by b.id) filter (
           where c.starts_at + make_interval(mins => s.duration_minutes) <= checked_at
         ), array[]::uuid[])
  into group_ids, ended_group_ids
  from public.bookings b join public.classes c on c.id = b.class_id
  join public.services s on s.id = c.service_id
  where b.client_id = profile_id and b.membership_id = pass_id and b.status = 'attended'
    and b.membership_charged and b.refunded_at is null and not b.late_cancellation
    and c.kind = 'group' and c.status = 'scheduled';

  individual_ids := array(
    select b.id from public.bookings b join public.classes c on c.id = b.class_id
    where b.client_id = profile_id and b.membership_id is null and b.status = 'attended'
      and not b.membership_charged and b.refunded_at is null and not b.late_cancellation
      and c.kind = 'individual' and c.status = 'scheduled' and c.starts_at > checked_at
    order by b.id
  );
  restore_ids := group_ids;
  cancel_ids := ended_group_ids;
  if reviewed_individual_id is not null and reviewed_individual_id = any(individual_ids) then
    restore_ids := array_append(restore_ids, reviewed_individual_id);
  end if;

  selected_ids := restore_ids || cancel_ids;
  expected_reserve := confirmed_before + cardinality(group_ids);

  select coalesce(jsonb_agg(jsonb_build_object(
    'booking_id', b.id, 'class_id', c.id, 'kind', c.kind,
    'starts_at_belgrade', c.starts_at at time zone 'Europe/Belgrade',
    'membership_id', b.membership_id, 'status_before', b.status,
    'charged_before', b.membership_charged, 'selected', b.id = any(selected_ids),
    'status_after_if_selected', case when b.id = any(restore_ids) then 'confirmed'
      when b.id = any(cancel_ids) then 'cancelled' else b.status end,
    'charged_after_if_selected', case when b.id = any(selected_ids) then false else b.membership_charged end
  ) order by c.starts_at, b.id), '[]'::jsonb)
  into planned_rows
  from public.bookings b join public.classes c on c.id = b.class_id
  where b.id = any(group_ids) or b.id = any(ended_group_ids) or b.id = any(individual_ids);

  select coalesce(jsonb_object_agg(c.id, c.occupied_seats - (
    select count(*)::integer from public.bookings b where b.class_id = c.id and b.id = any(cancel_ids)
  )), '{}'::jsonb)
  into occupancy_expected from public.classes c
  where exists (select 1 from public.bookings b where b.class_id = c.id and b.id = any(selected_ids));

  select exists (
    select 1 from pg_catalog.pg_trigger t
    where t.tgrelid = 'public.bookings'::regclass and t.tgname = 'bookings_update_membership_reservation'
      and t.tgenabled = 'O' and t.tgfoid = to_regprocedure('harmony_private.sync_membership_reservation()')
      and (t.tgtype::integer & 2) <> 0
  ) and exists (
    select 1 from pg_catalog.pg_trigger t
    where t.tgrelid = 'public.bookings'::regclass and t.tgname = 'bookings_sync_seats'
      and t.tgenabled in ('O', 'A') and t.tgfoid = to_regprocedure('harmony_private.sync_booking_seats()')
  ) and (
    select count(*) = 3 from pg_catalog.pg_class
    where relrowsecurity and oid in ('public.classes'::regclass, 'public.bookings'::regclass, 'public.memberships'::regclass)
  ) into schema_ok;

  -- This particular legacy balance already holds all five seats and sessions.
  -- A different balance needs separate investigation, even for the same client.
  preflight_ok := coalesce(schema_ok and pass.id is not null
    and pass.total_sessions = 8 and pass.remaining_sessions = 6 and pass.reserved_sessions = 5
    and linked_attended = 5 and confirmed_before = 0
    and cardinality(group_ids) + cardinality(ended_group_ids) = 5
    and not exists (
      select 1 from jsonb_each_text(occupancy_expected) j where j.value::integer < 0
    ), false);
  selection_ok := coalesce(cardinality(reviewed_upcoming_group_ids) = cardinality(group_ids)
    and reviewed_upcoming_group_ids <@ group_ids and group_ids <@ reviewed_upcoming_group_ids
    and cardinality(reviewed_ended_group_ids) = cardinality(ended_group_ids)
    and reviewed_ended_group_ids <@ ended_group_ids and ended_group_ids <@ reviewed_ended_group_ids
    and (reviewed_individual_id is null or reviewed_individual_id = any(individual_ids)), false);

  if apply_changes then
    if not preflight_ok or not selection_ok then
      raise exception 'Preflight failed. Run the preview and check the profile, balance, dates, and reviewed booking UUIDs.';
    end if;

    -- The normal accounting trigger prohibits reversing attendance. Run the
    -- reviewed correction under the lock, retaining future holds and releasing
    -- ended holds explicitly. The seat trigger, constraints and RLS stay on.
    alter table public.bookings disable trigger bookings_update_membership_reservation;
    update public.bookings b
    set status = 'confirmed', membership_charged = false
    from public.classes c
    where b.id = any(restore_ids) and b.client_id = profile_id and b.class_id = c.id
      and b.status = 'attended' and b.refunded_at is null
      and c.status = 'scheduled' and c.starts_at > clock_timestamp();
    get diagnostics changed = row_count;

    update public.bookings b
    set status = 'cancelled', membership_charged = false, cancellation_source = 'admin'
    from public.classes c join public.services s on s.id = c.service_id
    where b.id = any(cancel_ids) and b.client_id = profile_id and b.class_id = c.id
      and b.status = 'attended' and b.refunded_at is null
      and c.status = 'scheduled'
      and c.starts_at + make_interval(mins => s.duration_minutes) <= clock_timestamp();
    get diagnostics cancelled_count = row_count;
    alter table public.bookings enable trigger bookings_update_membership_reservation;

    if changed <> cardinality(restore_ids) or cancelled_count <> cardinality(cancel_ids) then
      raise exception 'The reviewed bookings or class timing changed. The entire correction was rolled back.';
    end if;
    changed := changed + cancelled_count;
    update public.memberships set reserved_sessions = expected_reserve
    where id = pass_id and client_id = profile_id;

    select count(*) into confirmed_after
    from public.bookings b where b.client_id = profile_id and b.membership_id = pass_id and b.status = 'confirmed';
    select coalesce(jsonb_object_agg(c.id, c.occupied_seats), '{}'::jsonb)
    into occupancy_after from public.classes c
    where exists (select 1 from public.bookings b where b.class_id = c.id and b.id = any(selected_ids));
    if confirmed_after <> expected_reserve or occupancy_after is distinct from occupancy_expected
      or not exists (
        select 1 from public.memberships m where m.id = pass_id and m.client_id = profile_id
          and (m.remaining_sessions, m.reserved_sessions, m.total_sessions) =
              (pass.remaining_sessions, expected_reserve, pass.total_sessions)
      ) then
      raise exception 'Post-check failed: reservation count, class seats, or membership balance changed unexpectedly.';
    end if;
  end if;

  perform set_config('harmony_repair.future_attendance_result', jsonb_build_object(
    'applied', apply_changes,
    'preflight_ok', preflight_ok,
    'selection_ok', selection_ok,
    'booking_guards_and_rls_ok', schema_ok,
    'checked_at', checked_at,
    'profile_id', profile_id,
    'membership_id', pass_id,
    'group_candidate_ids', group_ids,
    'ended_group_candidate_ids', ended_group_ids,
    'unclassified_linked_attendance', linked_attended - cardinality(group_ids) - cardinality(ended_group_ids),
    'individual_candidates_for_this_profile', individual_ids,
    'individual_selected', reviewed_individual_id,
    'bookings_changed', changed,
    'stored_balance', jsonb_build_object('total', pass.total_sessions, 'remaining', pass.remaining_sessions,
      'reserved', pass.reserved_sessions, 'available', pass.remaining_sessions - pass.reserved_sessions),
    'confirmed_before', confirmed_before,
    'confirmed_after_if_applied', confirmed_after,
    'proposed_balance', case when preflight_ok then jsonb_build_object(
      'total', pass.total_sessions, 'remaining', pass.remaining_sessions,
      'reserved', expected_reserve, 'available', pass.remaining_sessions - expected_reserve
    ) end,
    'expected_confirmed_after_preview', case when preflight_ok then expected_reserve end,
    'planned_bookings', planned_rows
  )::text, true);
end;
$$;

select current_setting('harmony_repair.future_attendance_result')::jsonb as future_attendance_repair;
commit;
