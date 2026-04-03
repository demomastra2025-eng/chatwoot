const toNumber = value => {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
};

export const normalizeAccountLimit = limit => {
  if (!limit || typeof limit !== 'object') {
    return null;
  }

  const consumed = toNumber(limit.consumed);
  const totalCount = toNumber(limit.total_count ?? limit.totalCount);
  const unlimited = Boolean(limit.unlimited);
  const currentAvailable = toNumber(
    limit.current_available ?? limit.currentAvailable ?? totalCount - consumed
  );

  return {
    consumed,
    totalCount,
    currentAvailable: unlimited
      ? currentAvailable
      : Math.max(0, currentAvailable),
    unlimited,
  };
};

export const isAccountLimitExceeded = limit => {
  const normalizedLimit = normalizeAccountLimit(limit);

  if (!normalizedLimit || normalizedLimit.unlimited) {
    return false;
  }

  if (normalizedLimit.totalCount <= 0) {
    return normalizedLimit.consumed > 0;
  }

  return normalizedLimit.consumed >= normalizedLimit.totalCount;
};
