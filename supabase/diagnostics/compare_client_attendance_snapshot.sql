-- Run only once live_schema shows that load_studio_snapshot is installed.
-- SQL Editor owner reads the test profile link, then runs the same RPC as that
-- client with RLS. The transaction is read-only and its session settings roll back.
begin read only;
select set_config('request.jwt.claim.sub', coalesce((
  select auth_user_id::text from public.clients where id = '10000000-0000-4000-8000-000000000001'
), ''), true);
set local role authenticated;

with client_snapshot as materialized (
  select public.load_studio_snapshot(false) as data
), from_rpc as (
  select item
  from client_snapshot s cross join lateral jsonb_array_elements(s.data -> 'memberships') as item
)
select s.data ->> 'client_id' as client_profile_id,
       m.id as membership_id, m.name,
       m.remaining_sessions as db_remaining, m.reserved_sessions as db_reserved,
       (rpc.item ->> 'remaining_sessions')::integer as rpc_remaining,
       (rpc.item ->> 'reserved_sessions')::integer as rpc_reserved,
       m.remaining_sessions - m.reserved_sessions as db_available,
       (rpc.item ->> 'remaining_sessions')::integer - (rpc.item ->> 'reserved_sessions')::integer as rpc_available,
       case when m.id is null then null else
         coalesce((rpc.item ->> 'remaining_sessions')::integer = m.remaining_sessions
           and (rpc.item ->> 'reserved_sessions')::integer = m.reserved_sessions, false)
       end as balances_match
from client_snapshot s
left join public.memberships m on m.client_id = (s.data ->> 'client_id')::uuid
left join from_rpc rpc on rpc.item ->> 'id' = m.id::text
order by m.id;

rollback;
