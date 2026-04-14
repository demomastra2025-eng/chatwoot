export function parseDateValue(value) {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : new Date(value.getTime());
  }

  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

export function getDateMilliseconds(value) {
  return parseDateValue(value)?.getTime() ?? null;
}

export function compareDateValues(
  left,
  right,
  { order = 'asc', invalid = 'last' } = {}
) {
  const leftDate = parseDateValue(left);
  const rightDate = parseDateValue(right);

  if (!leftDate && !rightDate) return 0;
  if (!leftDate) return invalid === 'first' ? -1 : 1;
  if (!rightDate) return invalid === 'first' ? 1 : -1;

  return order === 'desc'
    ? rightDate.getTime() - leftDate.getTime()
    : leftDate.getTime() - rightDate.getTime();
}

export function durationBetweenDates(startedAt, endedAt) {
  const startedAtMs = getDateMilliseconds(startedAt);
  const endedAtMs = getDateMilliseconds(endedAt);

  if (startedAtMs === null || endedAtMs === null) {
    return null;
  }

  const duration = endedAtMs - startedAtMs;
  return duration >= 0 ? duration : null;
}

function parseUnixTimestamp(value) {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  const numericValue = Number(value);
  if (!Number.isFinite(numericValue)) {
    return null;
  }

  const milliseconds =
    Math.abs(numericValue) >= 1_000_000_000_000
      ? numericValue
      : numericValue * 1000;
  const parsed = new Date(milliseconds);

  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

export function formatTrendTimestamp(timestamp, locale, bucket = 'day') {
  const date = parseUnixTimestamp(timestamp);
  if (!date) return '';

  let options = { month: 'short', day: 'numeric' };

  if (bucket === 'hour') {
    options = { month: 'short', day: 'numeric', hour: 'numeric' };
  } else if (bucket === 'week') {
    options = { month: 'short', day: 'numeric' };
  }

  return new Intl.DateTimeFormat(locale || undefined, options).format(date);
}
