"use server";

import type { PostgrestError } from "@supabase/supabase-js";
import type { Booking, StudioSchedule, Direction, SessionKind } from "@/lib/demo";
import type { StudioCommand, StudioData } from "@/lib/supabase/model";
import { studioDateTime, studioTimestamp } from "@/lib/supabase/schedule-time";
import { studioSession } from "@/lib/supabase/server";

type ClientRow = { id: string; name: string; email: string | null };
type TrainerRow = { id: string; name: string; direction: Direction; active: boolean };
type ServiceRow = { id: string; direction: Direction; name: StudioSchedule["services"][number]["name"]; description: StudioSchedule["services"][number]["description"]; duration_minutes: number; price_amount: number; currency: string; active: boolean };
type ClassRow = { id: string; trainer_id: string; service_id: string; starts_at: string; kind: SessionKind; capacity: number; occupied_seats: number; status: string };
type BookingRow = {
  id: string; client_id: string; class_id: string; status: Booking["status"]; cancellation_source: Booking["cancellationSource"];
  membership_id: string | null; late_cancellation: boolean; membership_charged: boolean;
  refunded_at: string | null; refund_source: Booking["refundSource"]; refund_reason: string | null;
};
type MembershipRow = {
  id: string; client_id: string; name: string; total_sessions: number; remaining_sessions: number;
  reserved_sessions: number; direction: Direction | null; starts_on: string | null; expires_on: string | null;
};
type AssignmentRow = { trainer_id: string; service_id: string };
type SnapshotRow = {
  client_id: string | null; today: string; free_cancellation_hours?: number; clients: ClientRow[]; trainers: TrainerRow[];
  services: ServiceRow[]; classes: ClassRow[]; bookings: BookingRow[];
  memberships: MembershipRow[]; assignments: AssignmentRow[];
};

export async function loadStudio(admin: boolean): Promise<{ data?: StudioData; clientId?: string; error?: string; denied?: boolean }> {
  const session = await studioSession();
  if (!session.db || !session.userId) return { error: session.error ?? "Войдите, чтобы загрузить данные.", denied: true };
  const { data: rows, error } = await session.db.rpc("load_studio_snapshot", { p_admin: admin });
  const snapshot = rows as SnapshotRow | null;
  if (error || !snapshot) {
    if (error?.code === "PGRST202") return { error: "Примените миграцию загрузки данных студии в Supabase." };
    if (error?.code === "42501") {
      return { error: admin ? "Вход в CRM доступен только администраторам." : "Войдите, чтобы загрузить данные.", denied: true };
    }
    return { error: "Не удалось загрузить расписание и данные студии. Повторите попытку." };
  }
  if (snapshot.free_cancellation_hours === undefined) return { error: "Примените миграцию правил отмены и возвратов в Supabase." };
  const { clients, trainers, services, classes, bookings, memberships, assignments } = snapshot;
  const names = new Map(trainers.map((row) => [row.id, row.name]));
  const data: StudioData = {
    clients: clients.map((row) => ({ id: row.id, name: row.name, contact: row.email ?? "" })),
    employees: trainers.map((row) => ({
      ...row, serviceIds: assignments.filter((item) => item.trainer_id === row.id).map((item) => item.service_id),
    })),
    services: services.map((row) => ({
      id: row.id, direction: row.direction, name: row.name, description: row.description,
      duration: row.duration_minutes, price: row.price_amount, currency: row.currency, active: row.active,
    })),
    slots: classes.map((row) => ({
      id: row.id, service: row.service_id, employeeId: row.trainer_id, specialist: names.get(row.trainer_id) ?? "",
      ...studioDateTime(row.starts_at), startsAt: row.starts_at, kind: row.kind, capacity: row.capacity,
      occupiedSeats: row.occupied_seats, cancelled: row.status === "cancelled",
    })),
    bookings: bookings.map((row) => ({
      id: row.id, client: row.client_id, slot: row.class_id, status: row.status, cancellationSource: row.cancellation_source,
      membershipId: row.membership_id, lateCancellation: row.late_cancellation, membershipCharged: row.membership_charged,
      refundedAt: row.refunded_at, refundSource: row.refund_source, refundReason: row.refund_reason,
    })),
    memberships: memberships.map((row) => ({
      id: row.id, client: row.client_id, name: row.name, total: row.total_sessions, remaining: row.remaining_sessions,
      reserved: row.reserved_sessions, direction: row.direction, startsOn: row.starts_on, expiresOn: row.expires_on,
    })),
    today: snapshot.today,
    freeCancellationHours: snapshot.free_cancellation_hours,
  };
  return { data, clientId: snapshot.client_id ?? undefined };
}

function writeError(error: PostgrestError, type: StudioCommand["type"]) {
  if (error.code === "HF001") return "Доступные занятия по подходящему абонементу закончились.";
  if (error.code === "HF002") return "Новый период или направление не покрывает существующие резервы.";
  if (error.code === "HF003") return "Занятие уже началось. Запись закрыта.";
  if (error.code === "HF004") return "Занятие завершилось. Подтвердить заявку уже нельзя.";
  if (error.code === "HF005") return "Посещение можно отметить с начала занятия.";
  if (error.code === "HF006") return "Неявку можно отметить после окончания занятия.";
  if (error.code === "HF007") return "Нет списанного занятия для возврата или возврат уже выполнен.";
  if (error.code === "HF008") return "Возврат превысит исходное количество занятий. Проверьте остаток абонемента.";
  if (error.code === "HF009") return "Укажите причину возврата.";
  if (error.code === "40P01" || error.code === "40001") return "Данные изменились одновременно. Повторите попытку.";
  if (error.code === "42501" || error.code === "PGRST116") return "Действие недоступно или запись уже изменилась.";
  if (error.code === "23505" && type === "booking") return "У клиента уже есть запись на это занятие.";
  if (error.code === "23514") {
    if (type === "booking") return "Занятие недоступно или все места заняты.";
    if (type === "booking-status") return "Не удалось изменить статус записи. Проверьте статус занятия и остаток абонемента.";
    if (type === "class-status") return "Не удалось обновить занятие и его записи. Обновите расписание и повторите попытку.";
    if (type === "membership" || type === "new-membership") return "Проверьте даты и остаток. Остаток нельзя уменьшить ниже числа резервов.";
    if (type === "employee") return "Проверьте назначения услуг. Направление сотрудника с историей занятий изменить нельзя.";
    return "Проверьте значения полей и ограничения записи.";
  }
  return "Не удалось сохранить изменения. Повторите попытку.";
}

export async function updateStudio(command: StudioCommand): Promise<string | null> {
  const session = await studioSession();
  if (!session.db || !session.userId) return session.error ?? "Войдите, чтобы продолжить.";
  const { db } = session;

  let result: { error: PostgrestError | null };
  switch (command.type) {
    case "booking":
      result = await db.rpc("create_booking", { p_class_id: command.slot, ...(command.client ? { p_client_id: command.client } : {}) });
      break;
    case "booking-status":
      result = await db.rpc("change_booking", { p_booking_id: command.id, p_action: command.action });
      break;
    case "booking-refund":
      if (!command.reason.trim()) return "Укажите причину возврата.";
      result = await db.rpc("refund_studio_booking", { p_booking_id: command.id, p_reason: command.reason.trim() });
      break;
    case "cancellation-settings":
      if (!Number.isInteger(command.hours) || command.hours < 0 || command.hours > 2_147_483_647) return "Укажите целое неотрицательное число часов.";
      result = await db.from("studio_settings").update({ free_cancellation_hours: command.hours })
        .eq("singleton", true).select("singleton").single();
      break;
    case "client":
      result = await db.from("clients").insert({ name: command.name, email: command.email });
      break;
    case "employee":
      result = await db.rpc("save_studio_employee", {
        p_id: command.employee.id, p_name: command.employee.name, p_direction: command.employee.direction,
        p_service_ids: command.employee.serviceIds, p_active: command.employee.active, p_editing: command.editing,
      });
      break;
    case "employee-status":
      result = await db.from("trainers").update({ active: command.active }).eq("id", command.id).select("id").single();
      break;
    case "class": {
      const { slot } = command;
      const startsAt = studioTimestamp(slot.date, slot.time);
      if (!startsAt || !slot.employeeId || !Number.isSafeInteger(slot.capacity) || slot.capacity < 1) {
        return "Проверьте дату и время студии, сотрудника и число мест.";
      }
      const values = { trainer_id: slot.employeeId, service_id: slot.service, starts_at: startsAt, kind: slot.kind, capacity: slot.capacity };
      result = command.editing
        ? await db.from("classes").update(values).eq("id", slot.id).eq("status", "scheduled").select("id").single()
        : await db.from("classes").insert(values);
      break;
    }
    case "class-status":
      result = await db.from("classes").update({ status: command.cancelled ? "cancelled" : "scheduled" })
        .eq("id", command.id).eq("status", command.cancelled ? "scheduled" : "cancelled").select("id").single();
      break;
    case "price":
      result = await db.from("services").update({ price_amount: command.price }).eq("id", command.id).select("id").single();
      break;
    case "membership":
    case "new-membership": {
      if (!command.startsOn || !command.expiresOn || command.startsOn > command.expiresOn) return "Укажите корректный период абонемента.";
      result = await db.rpc("save_studio_membership", {
        p_direction: command.direction, p_starts_on: command.startsOn, p_expires_on: command.expiresOn,
        ...(command.type === "membership"
          ? { p_membership_id: command.id, p_remaining: command.remaining }
          : { p_client_id: command.client, p_name: command.name, p_total: command.total, p_remaining: command.total }),
      });
      if (result.error?.code === "PGRST202") return "Примените миграцию автоматического подтверждения заявок в Supabase.";
      break;
    }
    default:
      return "Действие недоступно.";
  }
  return result.error ? writeError(result.error, command.type) : null;
}
