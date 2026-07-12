import { resolveDealAmountMajor } from 'dashboard/components-next/CRM/dealAmount';

const stringCollator = new Intl.Collator(undefined, {
  numeric: true,
  sensitivity: 'base',
});

const compareNullableValues = (left, right) => {
  if (left === right) return 0;

  if (typeof left === 'string' || typeof right === 'string') {
    return stringCollator.compare(String(left), String(right));
  }

  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
};

export const normalizeSortText = value => {
  if (value === null || value === undefined) {
    return null;
  }

  const normalizedValue = String(value).trim().toLocaleLowerCase();
  return normalizedValue || null;
};

const timestampOrNull = value => (value ? new Date(value).getTime() : null);

const numberOrNull = value => {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  const numberValue = Number(value);
  return Number.isFinite(numberValue) ? numberValue : null;
};

export const createDealListSortValueResolver = ({
  ownerNameById = {},
  stageNameById = {},
} = {}) => {
  return (deal, key) => {
    switch (key) {
      case 'amount':
      case 'amountMinor':
        return numberOrNull(resolveDealAmountMajor(deal));
      case 'id':
        return Number(deal.id);
      case 'owner':
        return normalizeSortText(ownerNameById[deal.ownerId]);
      case 'stage':
        return normalizeSortText(stageNameById[deal.stageId]);
      case 'title':
        return normalizeSortText(deal.title);
      case 'updatedAt':
        return timestampOrNull(deal.updatedAt);
      default:
        return null;
    }
  };
};

const taskPriorityRank = {
  none: 0,
  low: 1,
  medium: 2,
  high: 3,
  urgent: 4,
};

export const createTaskListSortValueResolver = ({
  activityTypeLabelByValue = {},
  assigneeNameById = {},
  statusNameById = {},
} = {}) => {
  return (task, key) => {
    switch (key) {
      case 'activityType':
        return normalizeSortText(
          activityTypeLabelByValue[task.activityType] || task.activityType
        );
      case 'assignee':
        return normalizeSortText(assigneeNameById[task.assigneeId]);
      case 'dueAt':
        return timestampOrNull(task.dueAt);
      case 'id':
        return Number(task.id);
      case 'priority':
        return taskPriorityRank[task.priority] ?? null;
      case 'status':
        return normalizeSortText(statusNameById[task.statusId]);
      case 'title':
        return normalizeSortText(task.title);
      default:
        return null;
    }
  };
};

export const sortListRecords = (records, sortState, resolveValue) => {
  const sortKey = sortState?.key;
  const sortDirection = sortState?.direction;

  if (!sortKey || !sortDirection) {
    return records;
  }

  const directionMultiplier = sortDirection === 'asc' ? 1 : -1;

  return [...records].sort((left, right) => {
    const leftValue = resolveValue(left, sortKey);
    const rightValue = resolveValue(right, sortKey);
    const leftIsEmpty = leftValue === null || leftValue === undefined;
    const rightIsEmpty = rightValue === null || rightValue === undefined;

    if (leftIsEmpty && rightIsEmpty) return 0;
    if (leftIsEmpty) return 1;
    if (rightIsEmpty) return -1;

    const comparison = compareNullableValues(leftValue, rightValue);

    return comparison * directionMultiplier;
  });
};
