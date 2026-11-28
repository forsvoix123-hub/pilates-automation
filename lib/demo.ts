export type Locale = "ru" | "en" | "sr";
export type Direction = "pilates" | "beauty";
export type SessionKind = "group" | "individual";

type Localized = Record<Locale, string>;
type Service = {
  id: string; direction: Direction; name: Localized; description: Partial<Localized>;
  duration: number; price: number; currency: string; active: boolean;
};

export type Slot = {
  id: string; service: string; date: string; time: string; specialist: string; employeeId?: string;
  capacity: number; kind: SessionKind; cancelled?: boolean; occupiedSeats?: number; startsAt?: string;
};

export type Booking = {
  client: string; slot: string; status: "pending" | "confirmed" | "attended" | "no_show" | "cancelled" | "rejected";
  cancellationSource: "client" | "admin" | "class" | null;
  membershipId: string | null; lateCancellation: boolean; membershipCharged: boolean;
  refundedAt: string | null; refundSource: "admin" | "class" | null; refundReason: string | null;
};
export type Employee = { id: string; name: string; direction: Direction; serviceIds: string[]; active: boolean };

export type StudioSchedule = {
  clients: { id: string; name: string; contact: string }[];
  services: Service[];
  slots: Slot[];
  bookings: Booking[];
  employees: Employee[];
};

export function eligibleEmployees(state: Pick<StudioSchedule, "services" | "employees">, serviceId: string) {
  const direction = state.services.find((service) => service.id === serviceId && service.active !== false)?.direction;
  return state.employees.filter((employee) =>
    employee.active && employee.direction === direction && employee.serviceIds.includes(serviceId)
  );
}

export function matchingSlots(slots: Slot[], date: string, specialist: string) {
  return slots.filter((slot) => (!date || slot.date === date) && (!specialist || slot.specialist === specialist))
    .sort((a, b) => (a.date + a.time).localeCompare(b.date + b.time));
}

export function bookingOccupiesSeat(booking: Booking) {
  return booking.status === "pending" || booking.status === "confirmed" || booking.status === "attended" || booking.status === "no_show";
}

export function bookingDisplayStatus(booking: Booking, classCancelled = false) {
  if (booking.status !== "cancelled") return booking.status;
  if (booking.lateCancellation) return "lateCancelled";
  switch (booking.cancellationSource) {
    case "class": return "classCancelled";
    case "client": return "clientCancelled";
    case "admin": return "adminCancelled";
    default: return classCancelled ? "classCancelled" : "cancelled";
  }
}

export function seatsTaken(state: StudioSchedule, slot: Slot) {
  return slot.cancelled ? 0 : slot.occupiedSeats ?? state.bookings.filter((booking) => booking.slot === slot.id && bookingOccupiesSeat(booking)).length;
}

export function classHasStarted(slot: Slot, now = Date.now()) {
  return slot.startsAt !== undefined && Date.parse(slot.startsAt) <= now;
}

export function classHasEnded(slot: Slot, minutes: number | undefined, now = Date.now()) {
  return slot.startsAt !== undefined && minutes !== undefined && Date.parse(slot.startsAt) + minutes * 60_000 <= now;
}

export function freeCancellationUntil(slot: Slot, hours: number) {
  return slot.startsAt === undefined ? undefined : Date.parse(slot.startsAt) - hours * 3_600_000;
}

export function availableSlots(state: StudioSchedule) {
  return matchingSlots(state.slots.filter((slot) => !slot.cancelled && !classHasStarted(slot) && seatsTaken(state, slot) < slot.capacity), "", "");
}

export function formatDate(value: string, locale: Locale) {
  return new Intl.DateTimeFormat(locale === "sr" ? "sr-Latn" : locale, {
    weekday: "short", day: "numeric", month: "long", timeZone: "UTC",
  }).format(new Date(value));
}

export function formatPrice(value: number, locale: Locale, currency = "RSD") {
  return new Intl.NumberFormat(locale === "sr" ? "sr-Latn-RS" : locale, {
    style: "currency", currency, minimumFractionDigits: 0, maximumFractionDigits: 2,
  }).format(value);
}
