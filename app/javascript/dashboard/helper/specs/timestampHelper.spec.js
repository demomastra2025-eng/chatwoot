import { timestampInSeconds } from '../timestampHelper';

describe('#timestampInSeconds', () => {
  it('normalizes epoch seconds, milliseconds, and ISO timestamps', () => {
    const seconds = 1_710_000_000;

    expect(timestampInSeconds(seconds)).toBe(seconds);
    expect(timestampInSeconds(seconds * 1000)).toBe(seconds);
    expect(timestampInSeconds(new Date(seconds * 1000).toISOString())).toBe(
      seconds
    );
  });

  it('keeps numeric zero as the missing-activity sentinel', () => {
    expect(timestampInSeconds(0)).toBe(0);
    expect(timestampInSeconds('0')).toBe(0);
  });

  it('rejects malformed and unsupported values', () => {
    expect(timestampInSeconds('not-a-date')).toBeNull();
    expect(timestampInSeconds({ timestamp: 1_710_000_000 })).toBeNull();
    expect(timestampInSeconds(-1)).toBeNull();
  });
});
