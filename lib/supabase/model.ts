import { bookingOccupiesSeat, type Booking, type Direction, type StudioSchedule, type Employee, type Slot } from "@/lib/demo";

type MembershipPeriod = { direction: Direction; startsOn: string; expiresOn: string };
export type Membership = {
  id: string; client: string; name: string; total: number; remaining: number; reserved: number;
  direction: Direction | null; startsOn: string | null; expiresOn: string | null;
};
export type StudioData = Omit<StudioSchedule, "bookings"> & {
  bookings: (Booking & { id: string })[];
  memberships: Membership[];
  today: string;
  freeCancellationHours: number;
};

export type StudioCommand =
  | { type: "booking"; slot: string; client?: string }
  | { type: "booking-status"; id: string; action: "approve" | "reject" | "attend" | "no-show" | "cancel" }
  | { type: "booking-refund"; id: string; reason: string }
  | { type: "cancellation-settings"; hours: number }
  | { type: "client"; name: string; email: string }
  | { type: "employee"; employee: Employee; editing: boolean }
  | { type: "employee-status"; id: string; active: boolean }
  | { type: "class"; slot: Slot; editing: boolean }
  | { type: "class-status"; id: string; cancelled: boolean }
  | { type: "price"; id: string; price: number }
  | ({ type: "new-membership"; client: string; name: string; total: number } & MembershipPeriod)
  | ({ type: "membership"; id: string; remaining: number } & MembershipPeriod);

export function membershipStatus(item: Membership, date: string) {
  if (!item.direction) return "unconfigured";
  if (item.startsOn && item.startsOn > date) return "future";
  if (item.expiresOn && item.expiresOn < date) return "expired";
  return "active";
}

export function bookingMode(state: StudioData, client: string | undefined, slot: Slot) {
  if (!client || slot.kind === "individual") return "request";
  const direction = state.services.find((service) => service.id === slot.service)?.direction;
  const matching = state.memberships.filter((item) =>
    item.client === client && item.direction === direction && membershipStatus(item, slot.date) === "active"
  );
  if (matching.length === 0) return "request";
  return matching.some((item) => item.remaining > item.reserved) ? "book" : "exhausted";
}

export function bookingForSchedule(state: StudioData, slot: Slot) {
  const attempts = state.bookings.filter((booking) => booking.slot === slot.id);
  const active = attempts.find(bookingOccupiesSeat);
  const previous = attempts[0]?.status;
  return { active, retry: !active && (previous === "rejected" || previous === "cancelled") };
}
