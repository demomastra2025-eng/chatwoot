import { describe, expect, it } from 'vitest';

import {
  DEFAULT_STAGE_COLOR,
  STAGE_STANDARD_COLORS,
  getUnavailableStageColors,
  pickStageColor,
  resolveStageDisplayColor,
} from './stageColors';

describe('stageColors', () => {
  it('returns the default stage color when there are no stages yet', () => {
    expect(pickStageColor([], STAGE_STANDARD_COLORS)).toBe(DEFAULT_STAGE_COLOR);
  });

  it('exposes the 21 unique amoCRM stage colors', () => {
    expect(STAGE_STANDARD_COLORS).toHaveLength(21);
    expect(new Set(STAGE_STANDARD_COLORS).size).toBe(21);
    expect(STAGE_STANDARD_COLORS).not.toContain('#FFFFFF');
  });

  it('returns the first unused palette color', () => {
    expect(
      pickStageColor(
        [{ color: DEFAULT_STAGE_COLOR }, { color: '#FFF000' }],
        STAGE_STANDARD_COLORS
      )
    ).toBe('#FEFD7F');
  });

  it('does not block repeated standard colors', () => {
    expect(
      getUnavailableStageColors(
        [
          { id: 1, color: DEFAULT_STAGE_COLOR },
          { id: 2, color: '#FEFD7F' },
        ],
        STAGE_STANDARD_COLORS,
        2
      )
    ).toEqual([]);
  });

  it('renders legacy persisted colors with the amoCRM palette without changing data', () => {
    expect(resolveStageDisplayColor('#2563eb')).toBe('#C1E0FD');
    expect(resolveStageDisplayColor('#16A34A')).toBe('#87F1C0');
    expect(resolveStageDisplayColor('#123456')).toBe('#123456');
  });
});
