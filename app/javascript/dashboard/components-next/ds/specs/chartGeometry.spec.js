import {
  columnPath,
  linePath,
  nearestIndex,
  niceMax,
  rampStep,
  visibleTickIndexes,
  xPosition,
} from '../chartGeometry';

describe('chartGeometry', () => {
  it('rounds axis maxima to clean numbers', () => {
    expect(niceMax(260)).toBe(500);
    expect(niceMax(240)).toBe(250);
    expect(niceMax(22)).toBe(25);
    expect(niceMax(0)).toBe(1);
  });

  it('maps x positions and snaps the pointer to the nearest index', () => {
    const last = xPosition(13, 14);
    expect(nearestIndex(last, 14)).toBe(13);
    expect(nearestIndex(xPosition(5, 14) + 3, 14)).toBe(5);
    expect(nearestIndex(-100, 14)).toBe(0);
  });

  it('breaks the line at missing values', () => {
    const path = linePath(
      [1, null, 3],
      index => index,
      value => value
    );
    expect(path).toBe('M0.0 1.0 M2.0 3.0');
  });

  it('draws columns with a rounded top and a square baseline', () => {
    expect(columnPath(0, 10, 10, 20)).toMatch(/^M0 30 V14 Q0 10 4 10/);
    expect(columnPath(0, 10, 10, 0)).toBe('');
  });

  it('keeps about six x labels and always the last one', () => {
    expect(visibleTickIndexes(14)).toEqual([0, 3, 6, 9, 13]);
    expect(visibleTickIndexes(4)).toEqual([0, 1, 2, 3]);
    expect(visibleTickIndexes(0)).toEqual([]);
  });

  it('spreads stages over the ordinal ramp, earliest = strongest', () => {
    expect([0, 1, 2].map(index => rampStep(index, 3))).toEqual([1, 3, 5]);
    expect([0, 1, 2, 3, 4].map(index => rampStep(index, 5))).toEqual([
      1, 2, 3, 4, 5,
    ]);
    expect(rampStep(0, 1)).toBe(1);
  });
});
