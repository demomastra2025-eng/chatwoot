import { describe, expect, it } from 'vitest';

import {
  canRollbackOptimisticDeal,
  dealMatchesCreatedRange,
  isDealVersionNewer,
  sortDealsForBoard,
  stageCountsAfterDealMove,
} from './dealBoardState';

describe('dealBoardState', () => {
  it('sorts each stage by manual position without mixing stage slots', () => {
    const records = [
      { id: 1, position: 2, stageId: 10 },
      { id: 2, position: 2, stageId: 20 },
      { id: 3, position: 1, stageId: 10 },
      { id: 4, position: 1, stageId: 20 },
    ];

    expect(sortDealsForBoard(records).map(record => record.id)).toEqual([
      3, 4, 1, 2,
    ]);
  });

  it('respects the configured direction for server-backed board sorts', () => {
    const records = [
      { id: 1, stageId: 10, title: 'Alpha' },
      { id: 2, stageId: 10, title: 'Beta' },
    ];

    expect(
      sortDealsForBoard(records, {
        directions: { 10: 'desc' },
        key: 'title',
      }).map(record => record.id)
    ).toEqual([2, 1]);
  });

  it('moves one count between stages without mutating source metadata', () => {
    const counts = { 10: 3, 20: 4 };

    expect(
      stageCountsAfterDealMove(counts, { stageId: 10 }, { stageId: 20 })
    ).toEqual({ 10: 2, 20: 5 });
    expect(counts).toEqual({ 10: 3, 20: 4 });
  });

  it('matches inclusive created-at ranges', () => {
    const deal = { createdAt: '2026-09-04T12:00:00Z' };

    expect(
      dealMatchesCreatedRange(deal, {
        from: '2026-09-04T00:00:00Z',
        to: '2026-09-04T23:59:59Z',
      })
    ).toBe(true);
    expect(dealMatchesCreatedRange(deal, { to: '2026-09-04T11:59:59Z' })).toBe(
      false
    );
  });

  it('rolls back only while the optimistic version is still current', () => {
    const optimisticDeal = {
      id: 1,
      lockVersion: 4,
      position: 2,
      stageId: 20,
    };

    expect(
      canRollbackOptimisticDeal({ ...optimisticDeal }, optimisticDeal)
    ).toBe(true);
    expect(
      canRollbackOptimisticDeal(
        { ...optimisticDeal, lockVersion: 5 },
        optimisticDeal
      )
    ).toBe(false);
    expect(
      canRollbackOptimisticDeal(
        { ...optimisticDeal, position: 3 },
        optimisticDeal
      )
    ).toBe(false);
  });

  it('recognizes a newer realtime version than an API response', () => {
    expect(isDealVersionNewer({ lockVersion: 6 }, { lockVersion: 5 })).toBe(
      true
    );
    expect(isDealVersionNewer({ lockVersion: 5 }, { lockVersion: 5 })).toBe(
      false
    );
  });
});
