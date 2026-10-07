import { describe, expect, it } from 'vitest';

import {
  amountsAfterDealUpdate,
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

  it('moves an amount between stages while preserving the pipeline total', () => {
    const previousDeal = {
      amountMinor: 12500,
      currency: 'KZT',
      stageId: 10,
    };
    const nextDeal = { ...previousDeal, stageId: 20 };
    const stageAmounts = { 10: { KZT: 22500 }, 20: { USD: 5000 } };
    const pipelineAmounts = { KZT: 22500, USD: 5000 };

    expect(
      amountsAfterDealUpdate(stageAmounts, previousDeal, nextDeal, true)
    ).toEqual({ 10: { KZT: 10000 }, 20: { KZT: 12500, USD: 5000 } });
    expect(
      amountsAfterDealUpdate(pipelineAmounts, previousDeal, nextDeal)
    ).toEqual(pipelineAmounts);
    expect(stageAmounts[10].KZT).toBe(22500);
  });

  it('replaces an edited amount and currency without mutating previous totals', () => {
    const previous = { amountMinor: 12550, currency: 'KZT', stageId: 10 };
    const next = { amountMinor: 2075, currency: 'USD', stageId: 10 };
    const amounts = { 10: { KZT: 12550 } };

    expect(amountsAfterDealUpdate(amounts, previous, next, true)).toEqual({
      10: { USD: 2075 },
    });
    expect(amounts).toEqual({ 10: { KZT: 12550 } });
  });

  it('removes an archived or deleted deal amount from the visible totals', () => {
    const previous = { amountMinor: 12550, currency: 'KZT', stageId: 10 };

    expect(
      amountsAfterDealUpdate({ 10: { KZT: 12550 } }, previous, null, true)
    ).toEqual({ 10: {} });
  });

  it('does not add an amount for a deal whose previous version is unknown', () => {
    const next = { amountMinor: 12550, currency: 'KZT', stageId: 10 };
    const amounts = { 10: { KZT: 1000 } };

    expect(amountsAfterDealUpdate(amounts, null, next, true)).toEqual(amounts);
    expect(amountsAfterDealUpdate(amounts, undefined, next, true)).toEqual(
      amounts
    );
    expect(amountsAfterDealUpdate({ KZT: 1000 }, null, next, false)).toEqual({
      KZT: 1000,
    });
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
