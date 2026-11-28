const assert = require("node:assert/strict");
const { readdirSync, readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const { test } = require("node:test");
const { PGlite } = require("@electric-sql/pglite");

const sqlRoot = resolve(__dirname, "../supabase");
const migrations = readdirSync(resolve(sqlRoot, "migrations")).sort();
const latest = "20261125000700_harmony_attendance_balance.sql";
const cancellationRules = "20261125000900_harmony_cancellation_and_refunds.sql";
const uuid = (prefix, suffix) => `${prefix}0000000-0000-4000-8000-${String(suffix).padStart(12, "0")}`;
const admin = uuid(7, 1);
const client = uuid(7, 2);
const otherClient = uuid(7, 3);
const profile = uuid(1, 1);
const legacyMembership = uuid(6, 1);

async function fixture(t, { legacy = false } = {}) {
  const db = new PGlite();
  t.after(() => db.close());
  const query = (statement, values) => db.query(statement, values);
  const row = async (statement, values) => (await query(statement, values)).rows[0];
  const migrate = (file) => db.exec(readFileSync(resolve(sqlRoot, "migrations", file), "utf8"));
  await db.exec(`
    create role anon;
    create role authenticated;
    create schema auth;
    create table auth.users (id uuid primary key);
    grant usage on schema auth to authenticated;
    create function auth.uid() returns uuid language sql as
      $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  `);
  for (const file of migrations.filter((file) => !legacy || file < latest)) await migrate(file);
  await db.exec(readFileSync(resolve(sqlRoot, "seed.sql"), "utf8"));
  await query("insert into auth.users values ($1), ($2), ($3)", [admin, client, otherClient]);
  await query("insert into harmony_private.admin_users values ($1)", [admin]);
  await query("update public.clients set auth_user_id = $1 where id = $2", [client, profile]);
  await query("update public.clients set auth_user_id = $1 where id = $2", [otherClient, uuid(1, 3)]);
  await query(
    "update public.memberships set starts_on = current_date - 30, expires_on = current_date - 1 where id = $1",
    [legacyMembership],
  );

  async function as(user, task) {
    await db.exec("begin; set local role authenticated;");
    try {
      await query("select set_config('request.jwt.claim.sub', $1, true)", [user]);
      const result = await task();
      await db.exec("commit;");
      return result;
    } catch (error) {
      await db.exec("rollback;");
      throw error;
    }
  }

  return {
    query, row, as, migrate,
    async addClass(number, { kind = "group", day = number, capacity = kind === "individual" ? 1 : 2 } = {}) {
      const id = uuid(8, number);
      await query(
        `insert into public.classes(id, trainer_id, service_id, starts_at, kind, capacity)
         values ($1, $2, $3, (date_trunc('day', now() at time zone 'Europe/Belgrade')
           + $4::int * interval '1 day' + interval '12 hours') at time zone 'Europe/Belgrade', $5, $6)`,
        [id, uuid(2, 1), uuid(3, 1), day, kind, capacity],
      );
      return id;
    },
    issue: (count, { direction = "pilates", starts = -2, expires = 30 } = {}) => as(admin, () => row(`
      select * from public.save_studio_membership(
        $3, (now() at time zone 'Europe/Belgrade')::date + $4::int,
        (now() at time zone 'Europe/Belgrade')::date + $5::int, $1,
        p_client_id => $2, p_name => 'Test pass', p_total => $1
      )
    `, [count, profile, direction, starts, expires])),
    book: (classId, user = client) => as(user, () => row("select * from public.create_booking($1)", [classId])),
    change: (bookingId, action, user = admin) => as(user, () => row("select * from public.change_booking($1, $2)", [bookingId, action])),
    refund: (bookingId, reason, user = admin) => as(user, () => row("select * from public.refund_studio_booking($1, $2)", [bookingId, reason])),
    move: (classId, minutes) => query("update public.classes set starts_at = clock_timestamp() + $2::int * interval '1 minute' where id = $1", [classId, minutes]),
    balance: (id) => row(`
      select remaining_sessions as remaining, reserved_sessions as reserved,
             remaining_sessions - reserved_sessions as available
      from public.memberships where id = $1
    `, [id]),
    async seats(id) {
      return (await row("select occupied_seats from public.classes where id = $1", [id])).occupied_seats;
    },
  };
}

test("a cancelled booking can be submitted again only while a seat and future class are available", async (t) => {
  const db = await fixture(t);
  const classId = await db.addClass(1, { capacity: 1 });
  const request = await db.book(classId);
  assert.equal(request.status, "pending");
  await db.change(request.id, "reject");
  await assert.rejects(db.change(request.id, "approve"), { code: "42501" });
  assert.equal(await db.seats(classId), 0);
  const firstRetry = await db.book(classId);
  assert.equal(firstRetry.status, "pending");
  await db.change(firstRetry.id, "approve");
  assert.equal((await db.change(firstRetry.id, "cancel")).cancellation_source, "admin");
  await assert.rejects(db.change(firstRetry.id, "attend"), { code: "42501" });
  const secondRetry = await db.book(classId);
  assert.notEqual(secondRetry.id, firstRetry.id);
  assert.equal(secondRetry.status, "pending");
  assert.equal((await db.change(secondRetry.id, "cancel", client)).cancellation_source, "client");

  const membership = await db.issue(1);
  const direct = await db.book(classId);
  assert.equal(direct.status, "confirmed");
  assert.equal(direct.membership_id, membership.id);
  await assert.rejects(db.book(classId), { code: "23505" });
  await db.change(direct.id, "cancel");
  const occupied = await db.book(classId, otherClient);
  await assert.rejects(db.book(classId), { code: "23514" });
  await db.change(occupied.id, "cancel", otherClient);

  const beforeClassCancellation = await db.book(classId);
  assert.equal(beforeClassCancellation.status, "confirmed");
  assert.notEqual(beforeClassCancellation.id, direct.id);
  await db.as(admin, () => db.query("update public.classes set status = 'cancelled' where id = $1", [classId]));
  await assert.rejects(db.book(classId), { code: "23514" });
  assert.equal((await db.row("select cancellation_source from public.bookings where id = $1", [beforeClassCancellation.id])).cancellation_source, "class");
  assert.equal(await db.seats(classId), 0);
  assert.deepEqual(await db.balance(membership.id), { remaining: 1, reserved: 0, available: 1 });
  await db.as(admin, () => db.query("update public.classes set status = 'scheduled', starts_at = now() - interval '1 minute' where id = $1", [classId]));
  await assert.rejects(db.book(classId), { code: "HF003" });
});

test("automatic confirmation reserves once, cancellation releases, and attendance consumes once", async (t) => {
  const db = await fixture(t);
  const early = await db.addClass(1);
  const later = await db.addClass(2);
  const privateClass = await db.addClass(3, { kind: "individual" });
  const futureGroup = await db.addClass(4);
  const earlyRequest = await db.book(early);
  const laterRequest = await db.book(later);
  const individual = await db.book(privateClass);
  const membership = await db.issue(2);
  assert.deepEqual(await db.balance(membership.id), { remaining: 2, reserved: 2, available: 0 });
  for (const [request, classId] of [[earlyRequest, early], [laterRequest, later]]) {
    assert.deepEqual(await db.row("select status, membership_id from public.bookings where id = $1", [request.id]), {
      status: "confirmed", membership_id: membership.id,
    });
    assert.equal(await db.seats(classId), 1);
  }
  await assert.rejects(db.book(futureGroup), { code: "HF001" });
  await assert.rejects(db.change(earlyRequest.id, "attend", client), { code: "42501" });
  await assert.rejects(db.change(earlyRequest.id, "attend"), { code: "HF005" });
  await db.move(early, -5);
  await db.change(earlyRequest.id, "attend");
  assert.deepEqual(await db.balance(membership.id), { remaining: 1, reserved: 1, available: 0 });
  assert.equal(await db.seats(early), 1);
  await assert.rejects(db.change(earlyRequest.id, "attend"), { code: "42501" });
  await assert.rejects(db.change(earlyRequest.id, "cancel"), { code: "42501" });
  await db.query("update public.bookings set status = 'attended' where id = $1", [earlyRequest.id]);
  assert.deepEqual(await db.balance(membership.id), { remaining: 1, reserved: 1, available: 0 });

  await db.change(laterRequest.id, "cancel", client);
  assert.deepEqual(await db.balance(membership.id), { remaining: 1, reserved: 0, available: 1 });
  assert.equal((await db.change(individual.id, "approve")).membership_id, null);
  await db.move(privateClass, -5);
  assert.equal((await db.change(individual.id, "attend")).membership_id, null);
  const otherGroup = await db.addClass(5);
  const noPass = await db.book(otherGroup, otherClient);
  assert.equal((await db.change(noPass.id, "approve")).membership_id, null);
  await db.move(otherGroup, -5);
  assert.equal((await db.change(noPass.id, "attend")).membership_id, null);
  assert.deepEqual(await db.balance(membership.id), { remaining: 1, reserved: 0, available: 1 });
  assert.equal((await db.book(futureGroup)).status, "confirmed");
  assert.deepEqual(await db.balance(membership.id), { remaining: 1, reserved: 1, available: 0 });
  assert.equal((await db.as(otherClient, () => db.row("select id from public.memberships where id = $1", [membership.id]))), undefined);
});

test("migration settles an old attended hold without changing the available balance", async (t) => {
  const db = await fixture(t, { legacy: true });
  const oldVisit = await db.addClass(1);
  const upcoming = await db.addClass(2);
  const membership = await db.issue(3);
  const attended = await db.book(oldVisit);
  await db.change(attended.id, "attend");
  await db.book(upcoming);
  assert.deepEqual(await db.balance(membership.id), { remaining: 3, reserved: 2, available: 1 });
  await db.migrate(latest);
  assert.deepEqual(await db.balance(membership.id), { remaining: 2, reserved: 1, available: 1 });
  await db.migrate(latest);
  assert.deepEqual(await db.balance(membership.id), { remaining: 2, reserved: 1, available: 1 });
  await db.migrate("20261125000800_harmony_consistent_snapshot.sql");
  await db.migrate(cancellationRules);
  assert.deepEqual(await db.balance(membership.id), { remaining: 2, reserved: 1, available: 1 });
  assert.equal((await db.refund(attended.id, "Legacy attendance exception")).refund_source, "admin");
  assert.deepEqual(await db.balance(membership.id), { remaining: 3, reserved: 1, available: 2 });
});

test("dates and direction scope eligibility and several passes are used in expiry order", async (t) => {
  const db = await fixture(t);
  const noMatching = await db.addClass(4, { day: 2 });
  const exactEnd = await db.addClass(1, { day: 3 });
  const later = await db.addClass(2, { day: 10 });
  const nextNear = await db.addClass(3, { day: 2 });

  await db.issue(2, { direction: "beauty" });
  await db.issue(1, { starts: 20, expires: 25 });
  await db.issue(1, { starts: -5, expires: -1 });
  const request = await db.book(noMatching);
  assert.equal(request.status, "pending");
  await db.change(request.id, "cancel", client);

  const long = await db.issue(2);
  const short = await db.issue(1, { expires: 3 });
  assert.equal((await db.book(later)).membership_id, long.id);
  assert.equal((await db.book(exactEnd)).membership_id, short.id);
  assert.equal((await db.book(nextNear)).membership_id, long.id);
  assert.deepEqual(await db.balance(long.id), { remaining: 2, reserved: 2, available: 0 });
  assert.deepEqual(await db.balance(short.id), { remaining: 1, reserved: 1, available: 0 });
  await assert.rejects(db.book(noMatching), { code: "HF001" });
});

test("client and CRM snapshots respect RLS and include schedules beyond the PostgREST row limit", async (t) => {
  const db = await fixture(t);
  const session = await db.addClass(1, { capacity: 2 });
  const own = await db.book(session);
  const foreign = await db.book(session, otherClient);
  const pass = await db.issue(1);

  await db.query(`
    insert into public.classes(trainer_id, service_id, starts_at, kind, capacity)
    select $1, $2, now() + interval '3 days' + item * interval '1 minute', 'group', 2
    from generate_series(1, 1050) item
  `, [uuid(2, 1), uuid(3, 1)]);

  const snapshot = (user, adminView) => db.as(user, () => db.row(
    "select public.load_studio_snapshot($1) as snapshot", [adminView],
  )).then((record) => record.snapshot);
  const clientData = await snapshot(client, false);
  assert.equal(clientData.client_id, profile);
  assert(clientData.classes.length > 1000);
  assert.deepEqual(clientData.bookings.map((booking) => booking.id), [own.id]);
  assert(clientData.memberships.some((membership) => membership.id === pass.id && membership.reserved_sessions === 1));
  assert.deepEqual(clientData.assignments, []);
  assert.equal(clientData.classes.find((slot) => slot.id === session).occupied_seats, 2);
  assert.equal((await db.row("select has_function_privilege('anon', 'public.load_studio_snapshot(boolean)', 'execute') as allowed")).allowed, false);
  assert.equal((await db.row("select count(*)::int as count from pg_class where relrowsecurity and oid in ('public.clients'::regclass, 'public.trainers'::regclass, 'public.services'::regclass, 'public.trainer_services'::regclass, 'public.classes'::regclass, 'public.bookings'::regclass, 'public.memberships'::regclass)")).count, 7);
  await assert.rejects(snapshot(client, true), { code: "42501" });
  await assert.rejects(db.as(client, () => db.query("select user_id from harmony_private.admin_users")), { code: "42501" });
  assert.equal((await db.as(client, () => db.query("update public.classes set status = 'cancelled' where id = $1 returning id", [session]))).rowCount, 0);
  for (const action of ["approve", "reject", "cancel", "attend"]) {
    await assert.rejects(db.change(foreign.id, action, client), { code: "42501" });
  }
  await assert.rejects(db.as(client, () => db.query(
    "select public.create_booking($1, $2)", [session, uuid(1, 3)],
  )), { code: "42501" });
  await assert.rejects(db.as(otherClient, () => db.query(`
    select public.save_studio_membership('pilates', current_date, current_date + 20, 0, p_membership_id => $1)
  `, [pass.id])), { code: "42501" });
  await assert.rejects(db.as(otherClient, () => db.query("update public.memberships set remaining_sessions = 0 where id = $1", [pass.id])), { code: "42501" });
  await assert.rejects(db.as(client, () => db.query("update public.bookings set status = 'confirmed' where id = $1", [own.id])), { code: "42501" });
  const crmData = await snapshot(admin, true);
  assert(crmData.bookings.some((booking) => booking.id === foreign.id));
  assert(crmData.assignments.length > 0);
});

test("a future pass covers direct bookings and automatically confirms requests only inside its dates", async (t) => {
  const db = await fixture(t);
  const firstDay = await db.addClass(1, { day: 4 });
  const lastDay = await db.addClass(2, { day: 5 });
  const outside = await db.addClass(3, { day: 3 });
  const firstRequest = await db.book(firstDay);
  const outsideRequest = await db.book(outside);
  assert.equal(firstRequest.status, "pending");
  const pass = await db.issue(2, { starts: 4, expires: 5 });
  assert.equal(pass.reserved_sessions, 1);
  assert.equal((await db.row("select status from public.bookings where id = $1", [firstRequest.id])).status, "confirmed");
  assert.equal((await db.row("select status from public.bookings where id = $1", [outsideRequest.id])).status, "pending");
  assert.equal(await db.seats(firstDay), 1);
  const direct = await db.book(lastDay);
  assert.equal(direct.status, "confirmed");
  assert.equal(direct.membership_id, pass.id);
  assert.deepEqual(await db.balance(pass.id), { remaining: 2, reserved: 2, available: 0 });
});

test("CRM can approve during the class, attendance starts with the class, and no-show waits for its end", async (t) => {
  const db = await fixture(t);
  const ongoing = await db.addClass(1);
  const ended = await db.addClass(2);
  const request = await db.book(ongoing, otherClient);
  const expired = await db.book(ended, otherClient);
  await db.move(ongoing, -5);
  await db.move(ended, -60);
  await assert.rejects(db.book(ongoing), { code: "HF003" });
  assert.equal((await db.change(request.id, "approve")).status, "confirmed");
  await assert.rejects(db.change(request.id, "no-show"), { code: "HF006" });
  assert.equal((await db.change(request.id, "attend")).status, "attended");
  await assert.rejects(db.change(expired.id, "approve"), { code: "HF004" });
  assert.equal((await db.change(expired.id, "reject")).status, "rejected");
});

test("free cancellation releases a hold while late cancellation and no-show charge once", async (t) => {
  const db = await fixture(t);
  const settings = () => db.as(client, () => db.row("select free_cancellation_hours as hours from public.studio_settings"));
  assert.equal((await settings()).hours, 12);
  assert.equal((await db.as(client, () => db.query("update public.studio_settings set free_cancellation_hours = 0"))).rowCount, 0);
  await db.as(admin, () => db.query("update public.studio_settings set free_cancellation_hours = 4"));
  assert.equal((await settings()).hours, 4);
  const pass = await db.issue(3);
  const freeClass = await db.addClass(1);
  const lateClass = await db.addClass(2);
  const missedClass = await db.addClass(3);
  await db.move(freeClass, 241);
  await db.move(lateClass, 239);
  const free = await db.book(freeClass);
  const late = await db.book(lateClass);
  const missed = await db.book(missedClass);
  const freeResult = await db.change(free.id, "cancel", client);
  assert.equal(freeResult.late_cancellation, false);
  assert.deepEqual(await db.balance(pass.id), { remaining: 3, reserved: 2, available: 1 });
  const lateResult = await db.change(late.id, "cancel", client);
  assert.equal(lateResult.late_cancellation, true);
  assert.equal(lateResult.membership_charged, true);
  assert.deepEqual(await db.balance(pass.id), { remaining: 2, reserved: 1, available: 1 });
  await db.move(missedClass, -60);
  await assert.rejects(db.change(missed.id, "no-show", client), { code: "42501" });
  const missedResult = await db.change(missed.id, "no-show");
  assert.equal(missedResult.status, "no_show");
  assert.equal(missedResult.membership_charged, true);
  await assert.rejects(db.change(missed.id, "no-show"), { code: "42501" });
  await assert.rejects(db.change(missed.id, "attend"), { code: "42501" });
  assert.deepEqual(await db.balance(pass.id), { remaining: 1, reserved: 0, available: 1 });
  assert.equal(await db.seats(missedClass), 1);
  await db.as(admin, () => db.query("update public.classes set status = 'cancelled' where id = $1", [missedClass]));
  assert.deepEqual(await db.row("select status, refund_source from public.bookings where id = $1", [missed.id]),
    { status: "no_show", refund_source: "class" });
  assert.deepEqual(await db.balance(pass.id), { remaining: 2, reserved: 0, available: 2 });
});

test("an admin refund requires a reason and studio cancellation refunds only unsettled charges", async (t) => {
  const db = await fixture(t);
  const pass = await db.issue(3);
  const session = await db.addClass(1, { capacity: 1 });
  await db.move(session, 60);
  const first = await db.book(session);
  const firstCharge = await db.change(first.id, "cancel");
  assert.equal(firstCharge.membership_charged, true);
  await assert.rejects(db.refund(first.id, "Exception", client), { code: "42501" });
  await assert.rejects(db.refund(first.id, "  "), { code: "HF009" });
  const manual = await db.refund(first.id, "  Test exception  ");
  assert.equal(manual.refund_source, "admin");
  assert.equal(manual.refund_reason, "Test exception");
  await assert.rejects(db.refund(first.id, "Duplicate"), { code: "HF007" });

  const second = await db.book(session);
  await db.change(second.id, "cancel", client);
  const third = await db.book(session);
  assert.deepEqual(await db.balance(pass.id), { remaining: 2, reserved: 1, available: 1 });
  const studio = (status) => db.as(admin, () => db.query("update public.classes set status = $1 where id = $2", [status, session]));
  await studio("cancelled");
  assert.deepEqual(await db.balance(pass.id), { remaining: 3, reserved: 0, available: 3 });
  assert.equal((await db.row("select refund_source from public.bookings where id = $1", [first.id])).refund_source, "admin");
  assert.equal((await db.row("select refund_source from public.bookings where id = $1", [second.id])).refund_source, "class");
  assert.equal((await db.row("select cancellation_source from public.bookings where id = $1", [third.id])).cancellation_source, "class");
  await assert.rejects(db.refund(second.id, "Already returned"), { code: "HF007" });
  await studio("scheduled");
  await studio("cancelled");
  assert.deepEqual(await db.balance(pass.id), { remaining: 3, reserved: 0, available: 3 });

  const conflicting = await db.addClass(2);
  await db.move(conflicting, 60);
  const charge = await db.book(conflicting);
  await db.change(charge.id, "cancel", client);
  const stillConfirmed = await db.book(conflicting);
  await db.as(admin, () => db.query(`
    select public.save_studio_membership('pilates', current_date - 2, current_date + 30, 3, p_membership_id => $1)
  `, [pass.id]));
  await assert.rejects(db.as(admin, () => db.query("update public.classes set status = 'cancelled' where id = $1", [conflicting])),
    { code: "HF008" });
  assert.equal((await db.row("select status from public.classes where id = $1", [conflicting])).status, "scheduled");
  assert.equal((await db.row("select refunded_at from public.bookings where id = $1", [charge.id])).refunded_at, null);
  assert.equal((await db.row("select status from public.bookings where id = $1", [stillConfirmed.id])).status, "confirmed");
  assert.deepEqual(await db.balance(pass.id), { remaining: 3, reserved: 1, available: 2 });
});
