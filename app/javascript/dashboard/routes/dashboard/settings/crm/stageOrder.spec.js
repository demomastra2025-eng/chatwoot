import { describe, expect, it } from 'vitest';

import {
  isPositionLockedStage,
  movableStageIds,
  normalizeDraggedStageOrder,
  sortStages,
} from './stageOrder';

const stages = [
  { id: 1, code: 'new', outcome: 'open', position: 0 },
  { id: 2, code: 'qualified', outcome: 'open', position: 1 },
  { id: 3, code: 'proposal', outcome: 'open', position: 2 },
  { id: 4, code: 'review', outcome: 'open', position: 3 },
  { id: 5, code: 'negotiation', outcome: 'open', position: 4 },
  { id: 6, code: 'contract', outcome: 'open', position: 5 },
  { id: 7, code: 'won', outcome: 'won', position: 6 },
  { id: 8, code: 'lost', outcome: 'lost', position: 7 },
];

describe('CRM stage order', () => {
  it('locks unsorted, won and lost while leaving ordinary stages movable', () => {
    expect(
      stages.filter(isPositionLockedStage).map(stage => stage.code)
    ).toEqual(['new', 'won', 'lost']);
    expect(movableStageIds(stages)).toEqual([2, 3, 4, 5, 6]);
  });

  it('keeps all three system stages at fixed boundaries after drag', () => {
    const dragged = [
      stages[7],
      stages[5],
      stages[3],
      stages[0],
      stages[1],
      stages[4],
      stages[2],
      stages[6],
    ];

    expect(
      normalizeDraggedStageOrder(dragged).map(stage => stage.code)
    ).toEqual([
      'new',
      'contract',
      'review',
      'qualified',
      'negotiation',
      'proposal',
      'won',
      'lost',
    ]);
  });

  it('sorts technical first and statistical outcomes last despite stale positions', () => {
    const stalePositions = stages.map(stage => ({
      ...stage,
      position: 100 - stage.id,
    }));

    const codes = sortStages(stalePositions).map(stage => stage.code);

    expect(codes[0]).toBe('new');
    expect(codes.slice(-2)).toEqual(['won', 'lost']);
  });
});
