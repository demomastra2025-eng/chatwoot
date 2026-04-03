const compareNullableValues = (left, right) => {
  if (left === right) return 0;

  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
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
