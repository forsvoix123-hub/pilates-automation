"use client";

import { useState, type FormEvent, type ReactNode } from "react";
import Link from "next/link";
import { availableSlots, bookingDisplayStatus, classHasEnded, classHasStarted, eligibleEmployees, formatDate, formatPrice, freeCancellationUntil, seatsTaken, type StudioSchedule, type Direction, type SessionKind, type Slot } from "@/lib/demo";
import { logout } from "@/app/auth-actions";
import { studioDateTime } from "@/lib/supabase/schedule-time";
import type { Membership } from "@/lib/supabase/model";
import { useStudioData, useVisibleStudioRefresh } from "./studio-data";
import { ScheduleFilters, useScheduleFilters } from "./schedule-filters";
import { directions, Employees } from "./employees";

const sections = ["Обзор", "Клиенты", "Сотрудники", "Расписание", "Услуги", "Записи", "Абонементы"] as const;
type Section = (typeof sections)[number];
const kinds = { group: "Групповое", individual: "Индивидуальное" };
const bookingStatuses = {
  pending: "Ожидает подтверждения", confirmed: "Подтверждена", attended: "Посещение отмечено",
  cancelled: "Запись отменена", rejected: "Заявка отклонена", clientCancelled: "Клиент отменил запись",
  adminCancelled: "Администратор отменил запись", classCancelled: "Занятие отменено",
  no_show: "Неявка", lateCancelled: "Поздняя отмена",
};
const filterLabels = { date: "Дата", trainer: "Тренер / специалист", allTrainers: "Все специалисты", reset: "Сбросить" };

function Table({ headers, children }: { headers: string[]; children: ReactNode }) {
  return <div className="table-wrap"><table><thead><tr>{headers.map((label) => <th scope="col" key={label}>{label}</th>)}</tr></thead><tbody>{children}</tbody></table></div>;
}

function MembershipPeriodFields({ membership }: { membership?: Membership }) {
  return <>
    <label>Направление<select name="direction" required defaultValue={membership ? membership.direction ?? "" : "pilates"}>
      <option value="">Выберите направление</option>
      <option value="pilates">{directions.pilates}</option>
      <option value="beauty">{directions.beauty}</option>
    </select></label>
    <label>Дата начала<input required name="startsOn" type="date" defaultValue={membership?.startsOn ?? undefined} /></label>
    <label>Дата окончания<input required name="expiresOn" type="date" defaultValue={membership?.expiresOn ?? undefined} /></label>
  </>;
}

function membershipPeriod(data: FormData) {
  return { direction: String(data.get("direction")) as Direction, startsOn: String(data.get("startsOn")), expiresOn: String(data.get("expiresOn")) };
}

function SlotForm({ slot, state, onSave, onClose }: { slot?: Slot; state: StudioSchedule; onSave: (slot: Slot) => Promise<boolean>; onClose: () => void }) {
  const [kind, setKind] = useState<SessionKind>(slot?.kind ?? "group");
  const [direction, setDirection] = useState<Direction>(state.services.find((service) => service.id === slot?.service)?.direction ?? "pilates");
  const [service, setService] = useState(slot?.service ?? "");
  const [employeeId, setEmployeeId] = useState(slot?.employeeId ?? "");
  const employees = eligibleEmployees(state, service);
  const previousAssignment = slot?.service === service && slot?.employeeId && !employees.some((employee) => employee.id === slot.employeeId);
  return (
    <form className="inline-form" onSubmit={async (event) => {
      event.preventDefault();
      const form = event.currentTarget;
      const data = new FormData(form);
      const saved = await onSave({
        id: slot?.id ?? crypto.randomUUID(), service,
        date: String(data.get("date")), time: String(data.get("time")),
        specialist: "", employeeId, kind,
        capacity: kind === "individual" ? 1 : Number(data.get("capacity")),
      });
      if (saved && !slot) {
        form.reset();
        setKind("group");
        setDirection("pilates");
        setService("");
        setEmployeeId("");
      }
    }}>
      <label>Направление<select value={direction} onChange={(event) => {
        setDirection(event.target.value as Direction); setService(""); setEmployeeId("");
      }}><option value="pilates">{directions.pilates}</option><option value="beauty">{directions.beauty}</option></select></label>
      <label>Услуга<select required value={service} onChange={(event) => { setService(event.target.value); setEmployeeId(""); }}>
        <option value="">Выберите услугу</option>
        {state.services.filter((item) => item.direction === direction).map((item) => <option key={item.id} value={item.id}>{item.name.ru}</option>)}
      </select></label>
      <label>Формат<select value={kind} onChange={(event) => setKind(event.target.value as SessionKind)}><option value="group">{kinds.group}</option><option value="individual">{kinds.individual}</option></select></label>
      <label>Дата занятия<input required name="date" type="date" max="9999-12-31" defaultValue={slot?.date ?? studioDateTime(new Date()).date} /></label>
      <label>Время<input required name="time" type="time" defaultValue={slot?.time} /></label>
      <label>Тренер / специалист<select required value={employeeId} onChange={(event) => setEmployeeId(event.target.value)} disabled={!service}>
        <option value="">Выберите сотрудника</option>
        {previousAssignment && <option value={slot.employeeId}>{slot.specialist} (текущее назначение)</option>}
        {employees.map((employee) => <option key={employee.id} value={employee.id}>{employee.name}</option>)}
      </select></label>
      {kind === "group" && <label>Мест<input required name="capacity" type="number" min="1" defaultValue={slot?.capacity ?? 1} /></label>}
      <button className="button" disabled={!service || (!employees.length && !previousAssignment)}>{slot ? "Сохранить занятие" : "Добавить занятие"}</button>
      {slot && <button type="button" className="button" onClick={onClose}>Закрыть редактирование</button>}
      {service && !employees.length && !previousAssignment && <p className="basis-full">Для этой услуги нет активных сотрудников. Назначьте услугу сотруднику в разделе «Сотрудники».</p>}
    </form>
  );
}

export function Admin() {
  const [section, setSection] = useState<Section>("Обзор");
  const [notice, setNotice] = useState("");
  const [editing, setEditing] = useState<string>();
  const [formVersion, setFormVersion] = useState(0);
  const [participantsSlot, setParticipantsSlot] = useState("");
  const { state, save: persist, busy, refreshing, refresh } = useStudioData();
  useVisibleStudioRefresh(section === "Записи", refresh);
  const filters = useScheduleFilters(state.slots);
  const editingSlot = state.slots.find((slot) => slot.id === editing && !slot.cancelled);
  const bookable = availableSlots(state);
  const serviceName = (id: string) => state.services.find((service) => service.id === id)?.name.ru;
  const visibleBookings = participantsSlot ? state.bookings.filter((booking) => booking.slot === participantsSlot) : state.bookings;

  function save(event: FormEvent<HTMLFormElement>, action: (data: FormData, form: HTMLFormElement) => void) {
    event.preventDefault();
    setNotice("");
    action(new FormData(event.currentTarget), event.currentTarget);
  }

  async function createBooking(data: FormData) {
    const client = String(data.get("client"));
    const slot = String(data.get("slot"));
    if (await persist({ type: "booking", client, slot })) setNotice("Запись добавлена.");
  }

  return (
    <div className="admin-shell">
      <aside className="sidebar">
        <Link className="wordmark" href="/">HARMONY <span>FAMILY</span></Link>
        <nav aria-label="Разделы CRM">
          {sections.map((item) => <button key={item} aria-current={section === item ? "page" : undefined} onClick={() => {
            setSection(item); setParticipantsSlot(""); setNotice("");
            if (item === "Записи") void refresh();
          }}>{item}</button>)}
        </nav>
        <Link className="studio-link" href="/">Сайт студии</Link>
        <form action={logout}><button>Выйти</button></form>
      </aside>
      <main className="admin-main">
        <header className="admin-header"><div><p>Управление студией</p><h1>{section}</h1></div><span className="demo-label">Тестовые данные</span></header>
        <fieldset disabled={busy} className="min-w-0">
        {section === "Обзор" && (
          <>
            <div className="grid gap-4 sm:grid-cols-3">
              {[["Клиенты", state.clients.length], ["Записи", state.slots.reduce((total, slot) => total + seatsTaken(state, slot), 0)], ["Абонементы с остатком", state.memberships.filter((item) => item.remaining > 0).length]].map(([label, count]) => <article className="card metric" key={label}><p>{label}</p><strong>{count}</strong></article>)}
            </div>
            <h2 className="admin-subheading">Расписание студии</h2>
            <Table headers={["Услуга", "Дата и время", "Специалист", "Занято"]}>
              {state.slots.filter((slot) => !slot.cancelled).map((slot) => <tr key={slot.id}><td>{serviceName(slot.service)}</td><td>{formatDate(slot.date, "ru")} · {slot.time}</td><td>{slot.specialist}</td><td>{seatsTaken(state, slot)} / {slot.capacity}</td></tr>)}
            </Table>
          </>
        )}
        {section === "Клиенты" && (
          <>
            <form className="inline-form" onSubmit={(event) => save(event, async (data, form) => {
              const name = String(data.get("name")).trim();
              const contact = String(data.get("contact")).trim();
              if (!name) { setNotice("Укажите имя клиента."); return; }
              if (await persist({ type: "client", name, email: contact })) {
                setNotice("Клиент добавлен.");
                form.reset();
              }
            })}>
              <label>Имя<input required name="name" /></label>
              <label>Email<input required name="contact" type="email" /></label>
              <button className="button">Добавить клиента</button>
            </form>
            <Table headers={["Клиент", "Email"]}>{state.clients.map((client) => <tr key={client.id}><td>{client.name}</td><td>{client.contact}</td></tr>)}</Table>
          </>
        )}
        {section === "Сотрудники" && <Employees state={state} setNotice={setNotice} />}
        {section === "Расписание" && (
          <>
            <form className="inline-form" onSubmit={(event) => save(event, async (data) => {
              if (await persist({ type: "cancellation-settings", hours: Number(data.get("hours")) })) setNotice("Срок бесплатной отмены сохранён.");
            })}>
              <label>Бесплатная отмена за (часов)
                <input key={state.freeCancellationHours} name="hours" required type="number" min="0" step="1" defaultValue={state.freeCancellationHours} />
              </label>
              <button className="button">Сохранить срок</button>
            </form>
            <SlotForm key={editingSlot?.id ?? formVersion} slot={editingSlot} state={state} onClose={() => setEditing(undefined)} onSave={async (slot) => {
              const saved = await persist({ type: "class", slot, editing: Boolean(editingSlot) });
              if (saved) {
                setNotice(editingSlot ? "Занятие обновлено." : "Занятие добавлено.");
                setEditing(undefined);
              }
              return saved;
            }} />
            <ScheduleFilters filters={filters} labels={filterLabels} />
            <Table headers={["Услуга", "Дата и время", "Специалист", "Формат", "Занято", "Действия"]}>
              {filters.visible.map((slot) => <tr key={slot.id}>
                <td>{serviceName(slot.service)}</td><td>{formatDate(slot.date, "ru")} · {slot.time}</td><td>{slot.specialist}</td>
                <td>{kinds[slot.kind]}</td><td>{seatsTaken(state, slot)} / {slot.capacity}</td>
                <td><div className="flex flex-wrap gap-2">
                <button className="button" onClick={() => {
                  setParticipantsSlot(slot.id); setSection("Записи"); setNotice("");
                  void refresh();
                }}>Участники</button>
                {slot.cancelled ? <div className="flex flex-wrap items-center gap-2">
                  <span>Отменено</span><button className="button" onClick={async () => {
                    setNotice("");
                    if (await persist({ type: "class-status", id: slot.id, cancelled: false })) setNotice("Занятие восстановлено. Прежние записи остаются отменёнными.");
                  }}>Восстановить занятие</button>
                </div> : <div className="flex flex-wrap gap-2">
                  <button className="button" onClick={() => { setEditing(slot.id); setNotice(""); }}>Редактировать</button>
                  <button className="button" onClick={async () => {
                    if (!window.confirm("Отменить занятие и вернуть ранее списанные занятия на абонементы?")) return;
                    setNotice("");
                    const saved = await persist({ type: "class-status", id: slot.id, cancelled: true });
                    if (saved && editing === slot.id) setEditing(undefined);
                    if (saved) setNotice("Занятие отменено. Резервы освобождены, списанные занятия возвращены.");
                  }}>Отменить занятие</button>
                </div>}
                </div></td>
              </tr>)}
            </Table>
            {filters.visible.length === 0 && <p className="mt-4">Занятий по выбранным фильтрам нет.</p>}
          </>
        )}
        {section === "Услуги" && (
          <Table headers={["Услуга", "Цена", "Длительность", "Изменить цену"]}>
            {state.services.map((service) => <tr key={service.id}><td>{service.name.ru}</td><td>{formatPrice(service.price, "ru", service.currency)}</td><td>{service.duration} мин</td><td>
              <form className="row-form" onSubmit={(event) => save(event, async (data) => {
                if (await persist({ type: "price", id: service.id, price: Number(data.get("price")) })) setNotice("Цена сохранена.");
              })}><input aria-label={`Цена: ${service.name.ru}`} name="price" type="number" min="0" step="0.01" required defaultValue={service.price} key={service.price} /><button className="button">Сохранить</button></form>
            </td></tr>)}
          </Table>
        )}
        {section === "Записи" && (
          <>
            {bookable.length ? <form className="inline-form" onSubmit={(event) => save(event, createBooking)}>
              <label>Клиент<select name="client" required><option value="">Выберите клиента</option>{state.clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select></label>
              <label>Занятие<select name="slot" required><option value="">Выберите занятие</option>{bookable.map((slot) => <option key={slot.id} value={slot.id}>{serviceName(slot.service)} · {formatDate(slot.date, "ru")} · {slot.time} · {slot.specialist}</option>)}</select></label>
              <button className="button">Создать запись</button>
            </form> : <div className="card mb-4">
              <p className="mb-3">Нет активных занятий со свободными местами. Добавьте занятие, чтобы создать запись.</p>
              <button className="button" onClick={() => {
                setEditing(undefined); setFormVersion((version) => version + 1); setNotice(""); setSection("Расписание");
              }}>Перейти к созданию занятия</button>
            </div>}
            <div className="inline-form">
              <label>Участники занятия<select value={participantsSlot} onChange={(event) => setParticipantsSlot(event.target.value)}>
                <option value="">Все занятия</option>
                {state.slots.map((slot) => <option key={slot.id} value={slot.id}>{serviceName(slot.service)} · {formatDate(slot.date, "ru")} · {slot.time} · {slot.specialist}</option>)}
              </select></label>
              <button className="button" disabled={refreshing} onClick={() => void refresh()}>
                {refreshing ? "Обновляем…" : "Обновить записи"}
              </button>
            </div>
            <Table headers={["Клиент", "Услуга", "Дата и время", "Статус", "Действия"]}>
              {visibleBookings.map((booking) => {
                const slot = state.slots.find((item) => item.id === booking.slot);
                const duration = state.services.find((item) => item.id === slot?.service)?.duration;
                const cutoff = slot && freeCancellationUntil(slot, state.freeCancellationHours);
                const actions = {
                  approve: { label: "Подтвердить", notice: "Заявка подтверждена." },
                  attend: { label: "Отметить посещение", notice: "Посещение отмечено." },
                  "no-show": { label: "Отметить неявку", notice: "Неявка отмечена." },
                  reject: { label: "Отклонить", notice: "Заявка отклонена." },
                  cancel: { label: "Отменить запись", notice: "Запись отменена." },
                };
                const allowedActions = booking.status === "pending" ? ["approve", "reject"] as const
                  : booking.status === "confirmed" ? ["attend", "no-show", "cancel"] as const : [];
                const started = slot && classHasStarted(slot);
                const ended = slot && classHasEnded(slot, duration);
                return <tr key={booking.id}>
                  <td>{state.clients.find((client) => client.id === booking.client)?.name}</td>
                  <td>{slot && serviceName(slot.service)}</td><td>{slot && `${formatDate(slot.date, "ru")} · ${slot.time}`}</td>
                  <td>{bookingStatuses[bookingDisplayStatus(booking, slot?.cancelled)]}
                    {slot?.cancelled && (booking.status === "attended" || booking.status === "no_show") && <p>Занятие отменено</p>}
                    {booking.refundedAt ? <p>Занятие возвращено{booking.refundSource === "admin" && booking.refundReason && ` · ${booking.refundReason}`}</p>
                      : booking.membershipCharged && <p>Списано одно занятие</p>}
                  </td>
                  <td>{slot && !slot.cancelled && allowedActions.length > 0 && <div className="flex flex-wrap gap-2">
                    {allowedActions.filter((action) =>
                      (action !== "approve" || !ended) && (action !== "attend" || started) && (action !== "no-show" || ended)
                    ).map((action) => <button className="button" key={action} onClick={async () => {
                      if (action === "cancel" && booking.membershipId && cutoff !== undefined && Date.now() > cutoff &&
                          !window.confirm("При поздней отмене будет списано одно занятие. Отменить запись?")) return;
                      setNotice("");
                      if (await persist({ type: "booking-status", id: booking.id, action })) setNotice(actions[action].notice);
                    }}>{actions[action].label}</button>)}
                  </div>}
                  {booking.membershipCharged && !booking.refundedAt && <form className="inline-form mt-2" onSubmit={(event) => save(event, async (data) => {
                    if (await persist({ type: "booking-refund", id: booking.id, reason: String(data.get("reason")) })) {
                      setNotice("Занятие возвращено на абонемент.");
                    }
                  })}>
                    <label>Причина возврата<input name="reason" required /></label>
                    <button className="button">Вернуть занятие</button>
                  </form>}</td>
                </tr>;
              })}
            </Table>
            {visibleBookings.length === 0 && <p className="mt-4">Записей пока нет.</p>}
          </>
        )}
        {section === "Абонементы" && (
          <>
          <form className="inline-form" onSubmit={(event) => save(event, async (data, form) => {
            const name = String(data.get("name")).trim();
            if (!name) { setNotice("Укажите название абонемента."); return; }
            if (await persist({ type: "new-membership", name, client: String(data.get("client")), total: Number(data.get("total")), ...membershipPeriod(data) })) {
              form.reset();
              setNotice("Абонемент добавлен.");
            }
          })}>
            <label>Клиент<select name="client" required><option value="">Выберите клиента</option>{state.clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select></label>
            <label>Название<input required name="name" /></label>
            <label>Количество занятий<input required name="total" type="number" min="1" /></label>
            <MembershipPeriodFields />
            <button className="button">Добавить абонемент</button>
          </form>
          <Table headers={["Клиент", "Абонемент", "Остаток", "Период и остаток"]}>
            {state.memberships.map((item) => <tr key={item.id}><td>{state.clients.find((client) => client.id === item.client)?.name}</td><td>{item.name}</td><td>
              <strong>{item.remaining} / {item.total}</strong><p>В резерве: {item.reserved}</p><p>Доступно: {item.remaining - item.reserved}</p>
            </td><td>
              <form className="inline-form !mb-0" key={JSON.stringify([item.remaining, item.direction, item.startsOn, item.expiresOn])} onSubmit={(event) => save(event, async (data) => {
                if (await persist({ type: "membership", id: item.id, remaining: Number(data.get("remaining")), ...membershipPeriod(data) })) setNotice("Абонемент обновлён.");
              })}>
                <MembershipPeriodFields membership={item} />
                <label>Остаток<input aria-label={`Остаток занятий: ${item.name}`} name="remaining" type="number" required min={item.reserved} max={item.total} defaultValue={item.remaining} /></label>
                <button className="button">Сохранить</button>
              </form>
            </td></tr>)}
          </Table>
          </>
        )}
        </fieldset>
        <p className="notice" role="status">{notice}</p>
      </main>
    </div>
  );
}
