import { describe, expect, it } from 'vitest';

import {
  filterVisibleBoardDeals,
  filterVisibleBoardStages,
  isTerminalStage,
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
