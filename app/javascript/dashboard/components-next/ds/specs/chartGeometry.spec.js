import {
  PAD_LEFT,
  columnPath,
  linePath,
  nearestIndex,
  niceMax,
  pointerToX,
  rampStep,
  visibleTickIndexes,
  xPosition,
} from '../chartGeometry';

describe('chartGeometry', () => {
  it('rounds axis maxima to clean numbers', () => {
    expect(niceMax(260)).toBe(300);
    expect(niceMax(140)).toBe(150);
    expect(niceMax(22)).toBe(30);
    expect(niceMax(8)).toBe(8);
    expect(niceMax(0)).toBe(1);
  });

  it('maps x positions and snaps the pointer to the nearest index', () => {
    const last = xPosition(13, 14);
    expect(nearestIndex(last, 14)).toBe(13);
    expect(nearestIndex(xPosition(5, 14) + 3, 14)).toBe(5);
    expect(nearestIndex(-100, 14)).toBe(0);
  });

  it('maps a pointer over the plot overlay onto the plot range', () => {
    // the overlay spans PAD_LEFT .. 708 (668 viewBox units) in a 334px box
    const box = { left: 100, width: 334 };

    expect(pointerToX(100, box)).toBe(PAD_LEFT);
    expect(pointerToX(100 + 334, box)).toBe(708);
    expect(pointerToX(100 + 167, box)).toBe(PAD_LEFT + 334);
    [0, 1, 7, 14].forEach(index => {
      const clientX = 100 + ((xPosition(index, 15) - PAD_LEFT) / 668) * 334;
      expect(nearestIndex(pointerToX(clientX, box), 15)).toBe(index);
    });
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
