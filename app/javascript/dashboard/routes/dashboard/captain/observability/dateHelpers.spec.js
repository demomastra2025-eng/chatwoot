import {
  compareDateValues,
  durationBetweenDates,
  formatTrendTimestamp,
  getDateMilliseconds,
  parseDateValue,
} from './dateHelpers';

describe('observability date helpers', () => {
  it('parses valid date values and rejects invalid ones', () => {
    expect(parseDateValue('2026-04-13T12:30:00.000Z')?.toISOString()).toBe(
      '2026-04-13T12:30:00.000Z'
    );
    expect(parseDateValue('not-a-date')).toBeNull();
  });

  it('returns milliseconds for valid values only', () => {
    expect(getDateMilliseconds('2026-04-13T12:30:00.000Z')).toBe(
      1_776_083_400_000
    );
    expect(getDateMilliseconds('not-a-date')).toBeNull();
  });

  it('sorts invalid values after valid ones by default', () => {
    expect(
      compareDateValues('2026-04-13T12:30:00.000Z', 'not-a-date')
    ).toBeLessThan(0);
    expect(
      compareDateValues('2026-04-14T12:30:00.000Z', '2026-04-13T12:30:00.000Z')
    ).toBeGreaterThan(0);
  });

  it('computes durations only when both timestamps are valid', () => {
    expect(
      durationBetweenDates(
        '2026-04-13T12:30:00.000Z',
        '2026-04-13T12:31:30.000Z'
      )
    ).toBe(90_000);
    expect(
      durationBetweenDates('2026-04-13T12:30:00.000Z', 'not-a-date')
    ).toBeNull();
  });

  it('formats trend timestamps defensively', () => {
    expect(formatTrendTimestamp(1_760_548_200, 'en')).toBeTruthy();
    expect(formatTrendTimestamp(1_760_548_200_000, 'en')).toBeTruthy();
    expect(formatTrendTimestamp('not-a-timestamp', 'en')).toBe('');
  });
});
