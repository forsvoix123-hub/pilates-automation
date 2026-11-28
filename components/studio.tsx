"use client";

import { useState } from "react";
import Link from "next/link";
import { bookingDisplayStatus, classHasStarted, freeCancellationUntil, formatDate, formatPrice, seatsTaken, type Direction, type Locale, type Slot } from "@/lib/demo";
import { logout } from "@/app/auth-actions";
import { bookingForSchedule, bookingMode, membershipStatus } from "@/lib/supabase/model";
import { useStudioData, useVisibleStudioRefresh } from "./studio-data";
import { ScheduleFilters, useScheduleFilters } from "./schedule-filters";

const messages = {
  ru: { title: "Время для себя", intro: "Осознанное движение и бережный уход в одном пространстве.", pilates: "Пилатес", beauty: "Косметология", catalog: "Услуги", schedule: "Расписание", account: "Мой кабинет", contact: "Связь", minute: "мин", book: "Записаться", cancel: "Отменить", full: "Мест нет", booked: "Вы записаны", noBookings: "У вас пока нет записей.", noSlots: "В этом направлении пока нет свободных дат в расписании.", plan: "Абонемент на пилатес", left: "Осталось занятий", contactTitle: "Связь с администратором", contactNote: "Демонстрационный адрес студии", subtitle: "Студия пилатеса и косметологии", language: "Язык", direction: "Направление", navigation: "Навигация" },
  en: { title: "Time for yourself", intro: "Mindful movement and gentle care in one space.", pilates: "Pilates", beauty: "Beauty", catalog: "Services", schedule: "Schedule", account: "My account", contact: "Contact", minute: "min", book: "Book", cancel: "Cancel", full: "Fully booked", booked: "Booked", noBookings: "You have no bookings yet.", noSlots: "There are no dates in the schedule for this area yet.", plan: "Pilates membership", left: "Sessions remaining", contactTitle: "Contact the studio", contactNote: "Demo studio address", subtitle: "Pilates and beauty studio", language: "Language", direction: "Area", navigation: "Navigation" },
  sr: { title: "Vreme za sebe", intro: "Svesno kretanje i nežna nega na jednom mestu.", pilates: "Pilates", beauty: "Kozmetologija", catalog: "Usluge", schedule: "Raspored", account: "Moj nalog", contact: "Kontakt", minute: "min", book: "Rezerviši", cancel: "Otkaži", full: "Popunjeno", booked: "Rezervisano", noBookings: "Još nemate rezervacija.", noSlots: "Još nema termina u rasporedu za ovu oblast.", plan: "Članarina za pilates", left: "Preostali treninzi", contactTitle: "Kontaktirajte studio", contactNote: "Primer adrese studija", subtitle: "Studio za pilates i kozmetologiju", language: "Jezik", direction: "Oblast", navigation: "Navigacija" },
};

const bookingMessages = {
  ru: { bookings: "Мои записи", group: "Групповые", individual: "Индивидуальные", request: "Отправить заявку", date: "Дата", trainer: "Тренер / специалист", allTrainers: "Все специалисты", reset: "Сбросить", noResults: "Занятий по выбранным фильтрам нет." },
  en: { bookings: "My bookings", group: "Group sessions", individual: "Private sessions", request: "Request a booking", date: "Date", trainer: "Instructor / specialist", allTrainers: "All specialists", reset: "Reset", noResults: "No sessions match these filters." },
  sr: { bookings: "Moje rezervacije", group: "Grupni termini", individual: "Individualni termini", request: "Pošalji zahtev", date: "Datum", trainer: "Trener / specijalista", allTrainers: "Svi specijalisti", reset: "Poništi", noResults: "Nema termina za izabrane filtere." },
};
const tabs = ["catalog", "schedule", "bookings", "account", "contact"] as const;
const directions = ["pilates", "beauty"] as const;
const languages = { ru: "Русский", en: "English", sr: "Srpski" };
const membershipLabels = {
  ru: { active: "Действует", expired: "Срок истёк", future: "Ещё не действует", unconfigured: "Требует настройки" },
  en: { active: "Active", expired: "Expired", future: "Not yet active", unconfigured: "Setup required" },
  sr: { active: "Aktivna", expired: "Istekla", future: "Još nije aktivna", unconfigured: "Potrebno podešavanje" },
};
const bookingStatusText = {
  ru: { pending: "Ожидает подтверждения", confirmed: "Подтверждена", rejected: "Заявка отклонена", cancelled: "Запись отменена", clientCancelled: "Вы отменили запись", adminCancelled: "Администратор отменил запись", classCancelled: "Занятие отменено", attended: "Посещение отмечено", retry: "Подать заявку повторно", refresh: "Обновить", refreshing: "Обновляем…", missingSlot: "Сведения о занятии недоступны" },
  en: { pending: "Awaiting approval", confirmed: "Confirmed", rejected: "Request declined", cancelled: "Booking cancelled", clientCancelled: "You cancelled the booking", adminCancelled: "The studio cancelled the booking", classCancelled: "Session cancelled", attended: "Attended", retry: "Submit another request", refresh: "Refresh", refreshing: "Refreshing…", missingSlot: "Session details are unavailable" },
  sr: { pending: "Čeka potvrdu", confirmed: "Potvrđeno", rejected: "Zahtev je odbijen", cancelled: "Rezervacija je otkazana", clientCancelled: "Otkazali ste rezervaciju", adminCancelled: "Studio je otkazao rezervaciju", classCancelled: "Termin je otkazan", attended: "Prisustvo je zabeleženo", retry: "Ponovo pošalji zahtev", refresh: "Osveži", refreshing: "Osvežavanje…", missingSlot: "Podaci o terminu nisu dostupni" },
};
const bookingAvailability = {
  ru: { bookAgain: "Записаться повторно", started: "Занятие уже началось" },
  en: { bookAgain: "Book again", started: "Session already started" },
  sr: { bookAgain: "Rezerviši ponovo", started: "Termin je već počeo" },
};
const cancellationText = {
  ru: { no_show: "Неявка", lateCancelled: "Поздняя отмена", freeUntil: "Бесплатная отмена до", lateWarning: "При отмене будет списано одно занятие. Отменить запись?", charged: "Списано одно занятие", refunded: "Одно занятие возвращено на абонемент" },
  en: { no_show: "No-show", lateCancelled: "Late cancellation", freeUntil: "Free cancellation until", lateWarning: "Cancelling now will use one membership session. Cancel this booking?", charged: "One membership session used", refunded: "One session returned to your membership" },
  sr: { no_show: "Nedolazak", lateCancelled: "Kasno otkazivanje", freeUntil: "Besplatno otkazivanje do", lateWarning: "Otkazivanjem se troši jedan termin iz članarine. Otkazati rezervaciju?", charged: "Iskorišćen je jedan termin", refunded: "Jedan termin je vraćen u članarinu" },
};
const accountText = {
  ru: { signOut: "Выйти", noProfile: "Попросите администратора привязать ваш аккаунт к профилю клиента.", noPlan: "У вас пока нет абонементов.", seats: "Свободных мест", exhausted: "Лимит абонемента исчерпан", available: "Доступно для записи", reserved: "В резерве", from: "с", until: "до", unbounded: "Даты не заданы" },
  en: { signOut: "Sign out", noProfile: "Ask the studio to link your account to a client profile.", noPlan: "You have no memberships yet.", seats: "Seats available", exhausted: "Membership limit reached", available: "Available to book", reserved: "Reserved", from: "From", until: "Until", unbounded: "No dates set" },
  sr: { signOut: "Odjavi se", noProfile: "Zamolite studio da poveže vaš nalog sa profilom klijenta.", noPlan: "Još nemate članarine.", seats: "Slobodna mesta", exhausted: "Limit članarine je dostignut", available: "Dostupno za rezervaciju", reserved: "Rezervisano", from: "Od", until: "Do", unbounded: "Datumi nisu podešeni" },
};

export function Studio() {
  const [locale, setLocale] = useState<Locale>("ru");
  const [direction, setDirection] = useState<Direction>("pilates");
  const [tab, setTab] = useState<(typeof tabs)[number]>("catalog");
  const { state, clientId, save, busy, refreshing, refresh } = useStudioData();
  const t = { ...messages[locale], ...bookingMessages[locale] };
  const account = accountText[locale];
  const statusText = { ...bookingStatusText[locale], ...cancellationText[locale] };
  const availability = bookingAvailability[locale];
  const visibleServices = state.services.filter((service) => service.direction === direction && service.active !== false);
  const filters = useScheduleFilters(state.slots.filter((slot) => !slot.cancelled && state.services.some((service) => service.direction === direction && service.id === slot.service)));
  const me = state.clients.find((client) => client.id === clientId);

  useVisibleStudioRefresh(Boolean(clientId) && (tab === "schedule" || tab === "bookings" || tab === "account"), refresh);

  function renderSlot(slot: Slot, history?: (typeof state.bookings)[number]) {
    const service = state.services.find((item) => item.id === slot.service);
    const schedule = history ? undefined : bookingForSchedule(state, slot);
    const booking = history ?? schedule?.active;
    const free = Math.max(0, slot.capacity - seatsTaken(state, slot));
    const mode = schedule && bookingMode(state, clientId, slot);
    const started = classHasStarted(slot);
    const cutoff = history?.status === "confirmed" && history.membershipId && !slot.cancelled
      ? freeCancellationUntil(slot, state.freeCancellationHours) : undefined;
    const status = booking && (booking.status === "confirmed" && !history
      ? t.booked : statusText[bookingDisplayStatus(booking, slot.cancelled)]);
    const action = started ? availability.started
      : free === 0 ? t.full
      : mode === "exhausted" ? account.exhausted
      : mode === "book" ? schedule?.retry ? availability.bookAgain : t.book
      : schedule?.retry ? statusText.retry
      : t.request;
    return (
      <li className="slot" key={history?.id ?? slot.id}>
        <div>
          <strong>{service?.name[locale]}</strong><p>{formatDate(slot.date, locale)} · {slot.time} · {slot.specialist}</p>
          {history && <p>{t[slot.kind]} · {status}</p>}
          {history && slot.cancelled && (history.status === "attended" || history.status === "no_show") && <p>{statusText.classCancelled}</p>}
          {cutoff !== undefined && <p>{statusText.freeUntil} {new Intl.DateTimeFormat(locale === "sr" ? "sr-Latn" : locale, {
            dateStyle: "medium", timeStyle: "short", timeZone: "Europe/Belgrade",
          }).format(cutoff)}</p>}
          {history?.membershipCharged && <p>{history.refundedAt ? statusText.refunded : statusText.charged}</p>}
          {!history && <p>{account.seats}: {free} / {slot.capacity}</p>}
        </div>
        {history ? !slot.cancelled && (history.status === "pending" || history.status === "confirmed") && (
          <button className="button" disabled={busy} onClick={() => {
            if (cutoff !== undefined && Date.now() > cutoff && !window.confirm(statusText.lateWarning)) return;
            void save({ type: "booking-status", id: history.id, action: "cancel" });
          }}>{t.cancel}</button>
        ) : (
          <button className="button" disabled={busy || !clientId || Boolean(booking) || started || free === 0 || mode === "exhausted"} onClick={() => void save({ type: "booking", slot: slot.id })}>
            {status ?? action}
          </button>
        )}
      </li>
    );
  }

  return (
    <div lang={locale === "sr" ? "sr-Latn" : locale} className="studio">
      <header className="studio-header frame">
        <Link className="wordmark" href="/">HARMONY <span>FAMILY</span></Link>
        <div className="flex flex-wrap items-center gap-2"><select aria-label={t.language} value={locale} onChange={(event) => setLocale(event.target.value as Locale)}>
          {(Object.keys(languages) as Locale[]).map((key) => <option key={key} value={key}>{languages[key]}</option>)}
        </select><form action={logout}><button className="button">{account.signOut}</button></form></div>
      </header>
      <main className="frame">
        <section className="hero">
          <div className="hero-copy"><p>{t.subtitle}</p><h1>{t.title}</h1><p>{t.intro}</p></div>
          <div className="hero-art" aria-hidden="true"><span /><span /><span /></div>
        </section>
        <nav className="tabs" aria-label={t.navigation}>
          {tabs.map((item) => <button key={item} aria-pressed={tab === item} onClick={() => {
            setTab(item);
            if (item === "schedule" || item === "bookings" || item === "account") void refresh();
          }}>{t[item]}</button>)}
        </nav>
        <section className="content" aria-labelledby="studio-section">
          <div className="section-heading">
            <h2 id="studio-section">{tab === "contact" ? t.contactTitle : t[tab]}</h2>
            {(tab === "catalog" || tab === "schedule") && (
              <div className="segmented" role="group" aria-label={t.direction}>
                {directions.map((item) => <button key={item} aria-pressed={direction === item} onClick={() => setDirection(item)}>{t[item]}</button>)}
              </div>
            )}
            {(tab === "bookings" || tab === "schedule") && (
              <button className="button" onClick={() => void refresh()} disabled={busy || refreshing}>
                {refreshing ? statusText.refreshing : statusText.refresh}
              </button>
            )}
          </div>
          {tab === "catalog" && (
            <div className="grid gap-4 md:grid-cols-2">
              {visibleServices.map((service) => (
                <article className="card" key={service.id}>
                  <h3>{service.name[locale]}</h3><p>{service.description[locale]}</p>
                  <div className="card-footer"><span>{service.duration} {t.minute} · {formatPrice(service.price, locale, service.currency)}</span><button className="button" onClick={() => { setTab("schedule"); void refresh(); }}>{t.schedule}</button></div>
                </article>
              ))}
            </div>
          )}
          {tab === "schedule" && (
            <>
              <ScheduleFilters filters={filters} labels={t} />
              {filters.visible.length === 0 && <p>{t.noResults}</p>}
              {(["group", "individual"] as const).map((kind) => {
                const sessions = filters.visible.filter((slot) => slot.kind === kind);
                return sessions.length > 0 && <section className="mb-5" key={kind}><h3 className="mb-3">{t[kind]}</h3><ul className="surface">{sessions.map((slot) => renderSlot(slot))}</ul></section>;
              })}
              {!clientId && <p role="status">{account.noProfile}</p>}
            </>
          )}
          {tab === "bookings" && (state.bookings.length ? <ul className="surface">{state.bookings.map((booking) => {
            const slot = state.slots.find((item) => item.id === booking.slot);
            return slot ? renderSlot(slot, booking) : (
              <li className="slot" key={booking.id}><div><strong>{statusText[bookingDisplayStatus(booking)]}</strong><p>{statusText.missingSlot}</p></div></li>
            );
          })}</ul> : <p>{clientId ? t.noBookings : account.noProfile}</p>)}
          {tab === "account" && (
            <div className="grid gap-4">
              {me ? <article className="card"><h3>{me.name}</h3>
                {state.memberships.length ? state.memberships.map((item) => (
                  <div key={item.id} className="mt-4">
                    <strong>{item.name}{item.direction && ` · ${t[item.direction]}`}</strong>
                    <p>{[
                      membershipLabels[locale][membershipStatus(item, state.today)],
                      item.startsOn && `${account.from} ${formatDate(item.startsOn, locale)}`,
                      item.expiresOn && `${account.until} ${formatDate(item.expiresOn, locale)}`,
                      !item.startsOn && !item.expiresOn && account.unbounded,
                    ].filter(Boolean).join(" · ")}</p>
                    <p>{t.left}: {item.remaining} / {item.total} · {account.reserved}: {item.reserved} · {account.available}: {item.direction && (!item.expiresOn || item.expiresOn >= state.today) ? item.remaining - item.reserved : 0}</p>
                  </div>
                )) : <p>{account.noPlan}</p>}
              </article> : <p>{account.noProfile}</p>}
            </div>
          )}
          {tab === "contact" && <article className="card"><p>{t.contactNote}</p><a className="contact-link" href="mailto:studio@example.com">studio@example.com</a></article>}
        </section>
      </main>
      <footer className="frame studio-footer">HARMONY FAMILY</footer>
    </div>
  );
}
