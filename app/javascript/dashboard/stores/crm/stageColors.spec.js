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

  it('returns the first unused palette color', () => {
    expect(
      pickStageColor(
        [{ color: DEFAULT_STAGE_COLOR }, { color: '#0EA5E9' }],
        STAGE_STANDARD_COLORS
      )
    ).toBe('#E8E8EC');
  });

  it('does not block repeated standard colors', () => {
    expect(
      getUnavailableStageColors(
        [
          { id: 1, color: DEFAULT_STAGE_COLOR },
          { id: 2, color: '#E8E8EC' },
        ],
        STAGE_STANDARD_COLORS,
        2
      )
    ).toEqual([]);
  });
});
