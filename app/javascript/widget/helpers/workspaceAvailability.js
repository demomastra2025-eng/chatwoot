// The server owns working hours, holidays, breaks and timezone rules. The
// widget only compares instants and formats the next opening for the visitor.
const intervalsOf = (intervals = []) =>
  intervals
    .map(({ starts_at: start, ends_at: end }) => [
      Date.parse(start),
      Date.parse(end),
    ])
    .filter(([start, end]) => Number.isFinite(start) && end > start)
    .sort(([left], [right]) => left - right);

export const isWithinAvailability = (time, intervals) => {
  const now = new Date(time).getTime();
  return intervalsOf(intervals).some(
    ([start, end]) => start <= now && now < end
  );
};

const civilDay = date =>
  Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / 86400000;

export const nextOpening = (time, intervals) => {
  const now = new Date(time);
  const next = intervalsOf(intervals).find(([start]) => start > now.getTime());
  if (!next) return null;

  const opening = new Date(next[0]);
  return {
    minutesUntilOpen: Math.ceil((opening.getTime() - now.getTime()) / 60000),
    daysUntilOpen: civilDay(opening) - civilDay(now),
    config: {
      openHour: opening.getHours(),
      openMinutes: opening.getMinutes(),
      dayOfWeek: opening.getDay(),
    },
  };
};
