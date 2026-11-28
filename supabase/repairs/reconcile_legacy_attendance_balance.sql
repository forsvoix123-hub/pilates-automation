-- Owner-run data migration for one reviewed membership. Start with the read-only
-- check_client_attendance_balance.sql diagnostic. Do not apply to future attendance.
-- Use charge_ids only for verified visits that still hold a reserve AND were not
-- deducted. Use release_only_ids for verified visits whose deduction was already
-- accounted for. A membership_charged flag alone does not prove an old debit.
-- The two arrays together must explain the entire excess reserve.
-- Run the whole file with apply_changes=false, then enable it only after review.
begin;
lock table public.classes, public.bookings, public.memberships in share row exclusive mode nowait;

with settings as (
  select false as apply_changes,
    '10000000-0000-4000-8000-000000000001'::uuid as profile_id,
    '60000000-0000-4000-8000-000000000001'::uuid as membership_id,
    6 as expected_remaining, 5 as expected_reserved,
    array[]::uuid[] as charge_ids, array[]::uuid[] as release_only_ids
), target as (
  select m.* from public.memberships m join settings x
    on m.id = x.membership_id and m.client_id = x.profile_id
), ledger as (
  select b.id, b.status, c.starts_at,
         to_jsonb(b) ->> 'refunded_at' as refunded_at,
         to_jsonb(b) ->> 'membership_charged' as charge_marker
  from public.bookings b join target m on m.id = b.membership_id and m.client_id = b.client_id
  join public.classes c on c.id = b.class_id
), chosen as (
  select id, true as charge_now from settings cross join lateral unnest(charge_ids) id
  union all
  select id, false from settings cross join lateral unnest(release_only_ids) id
), totals as (
  select count(*) filter (where status = 'confirmed')::integer as confirmed,
         count(*) filter (where status = 'attended' and starts_at > statement_timestamp())::integer as future_attended
  from ledger
), decisions as (
  select count(*)::integer as selected, count(distinct s.id)::integer as distinct_selected,
         count(*) filter (where s.charge_now)::integer as charge_count,
         count(*) filter (
           where coalesce(l.status, '') <> 'attended' or l.starts_at > statement_timestamp()
             or (s.charge_now and (l.refunded_at is not null or l.charge_marker = 'false'))
         )::integer as invalid_selected
  from chosen s left join ledger l on l.id = s.id
), plan as (
  select x.*, m.remaining_sessions, m.reserved_sessions, t.confirmed, t.future_attended,
         d.selected, d.charge_count,
         case
           when m.id is null then 'membership_or_profile_not_found'
           when t.future_attended > 0 then 'future_attendance_requires_review'
           when m.reserved_sessions = t.confirmed then 'no_excess_reserve'
           when m.reserved_sessions < t.confirmed then 'reserve_below_confirmed_count_requires_review'
           when m.remaining_sessions is distinct from x.expected_remaining
             or m.reserved_sessions is distinct from x.expected_reserved then 'balance_changed_since_diagnostic'
           when d.selected <> d.distinct_selected or d.invalid_selected > 0 then 'invalid_duplicate_or_refunded_booking'
           when d.selected <> m.reserved_sessions - t.confirmed then 'classify_every_excess_reservation'
           else 'ready'
         end as result
  from settings x left join target m on true cross join totals t cross join decisions d
), applied as (
  update public.memberships m
  set remaining_sessions = m.remaining_sessions - p.charge_count,
      reserved_sessions = p.confirmed
  from plan p
  where p.apply_changes and p.result = 'ready' and m.id = p.membership_id
    and m.remaining_sessions = p.remaining_sessions and m.reserved_sessions = p.reserved_sessions
  returning m.id, m.remaining_sessions, m.reserved_sessions
)
select p.membership_id, p.result, p.remaining_sessions as remaining_before, p.reserved_sessions as reserved_before,
       p.confirmed as confirmed_reservations, p.future_attended, p.selected as reviewed_bookings,
       case when p.result = 'ready' then p.remaining_sessions - p.charge_count end as proposed_remaining,
       case when p.result = 'ready' then p.confirmed end as proposed_reserved,
       a.id is not null as applied,
       a.remaining_sessions as remaining_after, a.reserved_sessions as reserved_after
from plan p left join applied a on a.id = p.membership_id;

commit;
