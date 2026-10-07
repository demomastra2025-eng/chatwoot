import { describe, expect, it } from 'vitest';

import {
  filterVisibleBoardDeals,
  filterVisibleBoardStages,
  isTerminalStage,
  visibleBoardTotals,
} from './boardVisibility';

describe('isTerminalStage', () => {
  it('recognizes won and lost outcomes case-insensitively', () => {
    expect(isTerminalStage({ outcome: 'won' })).toBe(true);
    expect(isTerminalStage({ outcome: 'LOST' })).toBe(true);
  });

  it('does not treat open or unknown outcomes as terminal', () => {
    expect(isTerminalStage({ outcome: 'open' })).toBe(false);
    expect(isTerminalStage({ outcome: 'custom' })).toBe(false);
    expect(isTerminalStage({})).toBe(false);
  });
});

describe('filterVisibleBoardStages', () => {
  const stages = [
    { id: 1, outcome: 'open' },
    { id: 2, outcome: 'won' },
    { id: 3, outcome: 'lost' },
  ];

  it('hides terminal stages by default', () => {
    expect(filterVisibleBoardStages(stages)).toEqual([stages[0]]);
  });

  it('includes terminal stages when explicitly requested', () => {
    expect(filterVisibleBoardStages(stages, true)).toEqual(stages);
  });

  it('never renders inactive stages', () => {
    expect(
      filterVisibleBoardStages([{ id: 4, active: false, outcome: 'open' }], true)
    ).toEqual([]);
  });
});

describe('visibleBoardTotals', () => {
  it('sums only rendered stages and keeps currencies separate', () => {
    const stages = [{ id: 1 }, { id: 2 }];
    const counts = { 1: 3, 2: 3, 3: 251 };
    const amounts = {
      1: { KZT: 37650 },
      2: { USD: 60075 },
      3: { KZT: 25074900 },
    };

    expect(visibleBoardTotals(stages, counts, amounts)).toEqual({
      amounts: { KZT: 37650, USD: 60075 },
      count: 6,
    });
    expect(visibleBoardTotals([...stages, { id: 3 }], counts, amounts)).toEqual({
      amounts: { KZT: 25112550, USD: 60075 },
      count: 257,
    });
  });
});

describe('filterVisibleBoardDeals', () => {
  it('removes deals whose stages are not rendered on the board', () => {
    const deals = [
      { id: 10, stageId: 1 },
      { id: 20, stageId: 2 },
      { id: 30, stageId: 3 },
    ];

    expect(filterVisibleBoardDeals(deals, [{ id: 1 }])).toEqual([deals[0]]);
  });
});
