import { resolveDealAmountMajor } from 'dashboard/components-next/CRM/dealAmount';

const timestampOrNull = value => {
  if (!value) return null;

  const timestamp = new Date(value).getTime();
  return Number.isFinite(timestamp) ? timestamp : null;
};

const numberOrNull = value => {
  if (value === null || value === undefined || value === '') return null;

  const number = Number(value);
  return Number.isFinite(number) ? number : null;
};

const resolveBoardSortValue = (deal, key) => {
  if (key === 'amount') return numberOrNull(resolveDealAmountMajor(deal));
  if (key === 'position') return numberOrNull(deal.position);
  if (key === 'title') {
    return String(deal.title || '')
      .trim()
      .toLocaleLowerCase();
  }
  if (['createdAt', 'expectedCloseOn', 'updatedAt'].includes(key)) {
    return timestampOrNull(deal[key]);
  }

  return null;
};

const compareBoardValues = (left, right) => {
  if (left === right) return 0;
  if (left === null || left === undefined || left === '') return 1;
  if (right === null || right === undefined || right === '') return -1;
  if (typeof left === 'string' || typeof right === 'string') {
    return String(left).localeCompare(String(right), undefined, {
      numeric: true,
      sensitivity: 'base',
    });
  }

  return left < right ? -1 : 1;
};

export const sortDealsForBoard = (
  records,
  { key = 'position', directions = {} } = {}
) => {
  const recordsByStage = new Map();

  records.forEach(record => {
    const stageId = Number(record.stageId);
    const stageRecords = recordsByStage.get(stageId) || [];
    stageRecords.push(record);
    recordsByStage.set(stageId, stageRecords);
  });

  recordsByStage.forEach((stageRecords, stageId) => {
    const direction =
      key === 'position' || directions[stageId] !== 'desc' ? 1 : -1;
    stageRecords.sort((left, right) => {
      return (
        compareBoardValues(
          resolveBoardSortValue(left, key),
          resolveBoardSortValue(right, key)
        ) * direction
      );
    });
  });

  return records.map(record =>
    recordsByStage.get(Number(record.stageId)).shift()
  );
};

export const stageCountsAfterDealMove = (
  stageCounts,
  previousDeal,
  nextDeal
) => {
  const previousStageId = Number(previousDeal?.stageId);
  const nextStageId = Number(nextDeal?.stageId);
  if (
    !stageCounts ||
    !Number.isFinite(previousStageId) ||
    !Number.isFinite(nextStageId) ||
    previousStageId === nextStageId
  ) {
    return stageCounts;
  }

  const nextCounts = { ...stageCounts };
  const previousKey = String(previousStageId);
  const nextKey = String(nextStageId);
  nextCounts[previousKey] = Math.max(
    0,
    Number(nextCounts[previousKey] || 0) - 1
  );
  nextCounts[nextKey] = Number(nextCounts[nextKey] || 0) + 1;
  return nextCounts;
};

export const dealMatchesCreatedRange = (deal, dateRange = {}) => {
  const createdAt = timestampOrNull(deal?.createdAt);
  if (createdAt === null) return !dateRange.from && !dateRange.to;

  const from = timestampOrNull(dateRange.from);
  const to = timestampOrNull(dateRange.to);
  if (from !== null && createdAt < from) return false;
  if (to !== null && createdAt > to) return false;
  return true;
};

export const canRollbackOptimisticDeal = (currentDeal, optimisticDeal) => {
  if (!currentDeal || !optimisticDeal) return false;

  return (
    Number(currentDeal.id) === Number(optimisticDeal.id) &&
    Number(currentDeal.stageId) === Number(optimisticDeal.stageId) &&
    Number(currentDeal.position) === Number(optimisticDeal.position) &&
    Number(currentDeal.lockVersion) === Number(optimisticDeal.lockVersion)
  );
};

export const isDealVersionNewer = (deal, candidate) => {
  const dealVersion = numberOrNull(deal?.lockVersion);
  const candidateVersion = numberOrNull(candidate?.lockVersion);
  if (dealVersion === null || candidateVersion === null) return false;

  return dealVersion > candidateVersion;
};
