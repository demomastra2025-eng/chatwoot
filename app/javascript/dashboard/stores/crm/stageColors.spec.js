import { describe, expect, it } from 'vitest';

import {
  DEFAULT_STAGE_COLOR,
  STAGE_STANDARD_COLORS,
  getUnavailableStageColors,
  pickStageColor,
} from './stageColors';

describe('stageColors', () => {
  it('returns the default stage color when there are no stages yet', () => {
    expect(pickStageColor([], STAGE_STANDARD_COLORS)).toBe(DEFAULT_STAGE_COLOR);
  });

  it('exposes 20 unique non-white spectrum colors', () => {
    expect(STAGE_STANDARD_COLORS).toHaveLength(20);
    expect(new Set(STAGE_STANDARD_COLORS).size).toBe(20);
    expect(STAGE_STANDARD_COLORS).not.toContain('#F0F0F3');
    expect(STAGE_STANDARD_COLORS).not.toContain('#E8E8EC');
    expect(STAGE_STANDARD_COLORS).not.toContain('#FFFFFF');
  });

  it('returns the first unused palette color', () => {
    expect(
      pickStageColor(
        [{ color: DEFAULT_STAGE_COLOR }, { color: '#EA580C' }],
        STAGE_STANDARD_COLORS
      )
    ).toBe('#DC2626');
  });

  it('does not block repeated standard colors', () => {
    expect(
      getUnavailableStageColors(
        [
          { id: 1, color: DEFAULT_STAGE_COLOR },
          { id: 2, color: '#DC2626' },
        ],
        STAGE_STANDARD_COLORS,
        2
      )
    ).toEqual([]);
  });
});
