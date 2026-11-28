const studioTime = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Belgrade", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});

export function studioDateTime(value: Date | string) {
  const parts = Object.fromEntries(studioTime.formatToParts(new Date(value)).map(({ type, value }) => [type, value]));
  return { date: `${parts.year}-${parts.month}-${parts.day}`, time: `${parts.hour}:${parts.minute}` };
}

export function studioTimestamp(date: string, time: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(time)) return null;
  const wall = Date.parse(`${date}T${time}:00Z`);
  if (!Number.isFinite(wall)) return null;
  // Try both offsets around a daylight-saving transition. Reject ambiguous or missing times.
  const offsets = new Set([-86400000, 86400000].map((delta) => {
    const sampled = wall + delta;
    const local = studioDateTime(new Date(sampled));
    return Date.parse(`${local.date}T${local.time}:00Z`) - sampled;
  }));
  const matches = [...offsets].map((offset) => new Date(wall - offset)).filter((candidate) => {
    const local = studioDateTime(candidate);
    return local.date === date && local.time === time;
  });
  return matches.length === 1 ? matches[0].toISOString() : null;
}
