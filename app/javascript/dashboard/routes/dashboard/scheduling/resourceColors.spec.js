import { describe, expect, it } from 'vitest';

import {
  getUnavailableResourceColors,
  pickResourceColor,
} from './resourceColors';

describe('resourceColors', () => {
  const palette = ['#111111', '#222222', '#333333'];

  it('returns the first palette color when there are no specialists yet', () => {
    expect(pickResourceColor([], palette)).toBe('#111111');
  });

  it('returns the first unused palette color', () => {
    expect(
      pickResourceColor([{ color: '#111111' }, { color: '#333333' }], palette)
    ).toBe('#222222');
  });

  it('matches used colors case-insensitively', () => {
    expect(
      pickResourceColor([{ color: '#111111' }], ['#111111', '#ABCDEF'])
    ).toBe('#ABCDEF');
  });

  it('returns unavailable standard colors excluding the edited specialist', () => {
    expect(
      getUnavailableResourceColors(
        [
          { id: 1, color: '#111111' },
          { id: 2, color: '#222222' },
        ],
        palette,
        2
      )
    ).toEqual(['#111111']);
  });

  it('falls back to the first palette color when all colors are taken', () => {
    expect(
      pickResourceColor(
        [{ color: '#111111' }, { color: '#222222' }, { color: '#333333' }],
        palette
      )
    ).toBe('#111111');
  });
});
