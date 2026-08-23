const MILLISECOND_TIMESTAMP_THRESHOLD = 1_000_000_000_000;

export const timestampInSeconds = value => {
  if (value === undefined || value === null || value === '') return null;

  const numericValue = Number(value);
  if (Number.isFinite(numericValue) && numericValue >= 0) {
    return numericValue >= MILLISECOND_TIMESTAMP_THRESHOLD
      ? numericValue / 1000
      : numericValue;
  }

  if (typeof value !== 'string') return null;

  const parsedValue = Date.parse(value);
  return Number.isFinite(parsedValue) && parsedValue >= 0
    ? parsedValue / 1000
    : null;
};
