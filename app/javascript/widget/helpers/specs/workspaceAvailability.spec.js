import { isWithinAvailability, nextOpening } from '../workspaceAvailability';

const intervals = [
  { starts_at: '2026-09-07T13:00:00Z', ends_at: '2026-09-07T17:00:00Z' },
  { starts_at: '2026-09-07T09:00:00Z', ends_at: '2026-09-07T12:00:00Z' },
];

describe('server availability projection', () => {
  it.each([
    ['2026-09-07T08:59:59Z', false],
    ['2026-09-07T09:00:00Z', true],
    ['2026-09-07T11:59:59Z', true],
    ['2026-09-07T12:00:00Z', false],
    ['2026-09-07T13:00:00Z', true],
    ['2026-09-07T17:00:00Z', false],
  ])('compares half-open instants at %s', (time, expected) => {
    expect(isWithinAvailability(time, intervals)).toBe(expected);
  });

  it('does not infer weekly rules across breaks or days off', () => {
    expect(isWithinAvailability('2026-09-08T10:00:00Z', intervals)).toBe(false);
    expect(nextOpening('2026-09-07T12:45:01Z', intervals)).toMatchObject({
      minutesUntilOpen: 15,
    });
  });

  it('selects the earliest future opening regardless of input order', () => {
    const opening = new Date('2026-09-07T09:00:00Z');
    expect(nextOpening('2026-09-07T08:50:00Z', intervals)).toMatchObject({
      minutesUntilOpen: 10,
      config: {
        openHour: opening.getHours(),
        openMinutes: opening.getMinutes(),
        dayOfWeek: opening.getDay(),
      },
    });
  });

  it('ignores malformed intervals and does not synthesize missing future slots', () => {
    const invalid = [
      { starts_at: 'invalid', ends_at: 'invalid' },
      { starts_at: '2026-09-07T12:00:00Z', ends_at: '2026-09-07T09:00:00Z' },
    ];
    expect(isWithinAvailability('2026-09-07T10:00:00Z', invalid)).toBe(false);
    expect(nextOpening('2026-09-07T18:00:00Z', intervals)).toBeNull();
    expect(nextOpening(new Date(), [])).toBeNull();
  });

  it('counts visitor calendar days across the DST clock change', () => {
    const previous = process.env.TZ;
    process.env.TZ = 'America/New_York';
    try {
      // The next opening is tomorrow even though it is less than 24h away.
      expect(
        nextOpening('2026-03-07T12:00:00-05:00', [
          {
            starts_at: '2026-03-08T09:00:00-04:00',
            ends_at: '2026-03-08T17:00:00-04:00',
          },
        ])
      ).toMatchObject({ daysUntilOpen: 1, minutesUntilOpen: 1200 });
    } finally {
      if (previous === undefined) delete process.env.TZ;
      else process.env.TZ = previous;
    }
  });
});
