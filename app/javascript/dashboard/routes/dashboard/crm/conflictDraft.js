import { extractCrmError } from 'dashboard/stores/crm/shared';

export const isStaleCrmError = error =>
  extractCrmError(error).code === 'STALE_RECORD';

export const assertCrmEditCurrent = (baseline, current) => {
  if (
    baseline &&
    Number(baseline.id) === Number(current?.id) &&
    Number(baseline.lockVersion) === Number(current?.lockVersion)
  ) {
    return;
  }

  const error = new Error('STALE_RECORD');
  error.response = { data: { code: 'STALE_RECORD' } };
  throw error;
};

export const changedObjectKeys = (baseline = {}, requested = {}) => {
  const changed = {};
  const baselineObject = baseline || {};
  const requestedObject = requested || {};
  const keys = new Set([
    ...Object.keys(baselineObject),
    ...Object.keys(requestedObject),
  ]);

  keys.forEach(key => {
    const requestedValue = Object.prototype.hasOwnProperty.call(
      requestedObject,
      key
    )
      ? requestedObject[key]
      : null;
    if (
      JSON.stringify(requestedValue) !== JSON.stringify(baselineObject[key])
    ) {
      changed[key] = requestedValue;
    }
  });

  return changed;
};

export const changedDraftPayload = (
  baseline = {},
  requested = {},
  excludedKeys = []
) => {
  const excluded = new Set(excludedKeys);
  const changed = Object.fromEntries(
    Object.entries(requested).filter(
      ([key, value]) =>
        key !== 'custom_attributes' &&
        !excluded.has(key) &&
        JSON.stringify(value) !== JSON.stringify(baseline[key])
    )
  );

  if (!excluded.has('custom_attributes')) {
    const customAttributes = changedObjectKeys(
      baseline.custom_attributes,
      requested.custom_attributes
    );
    if (Object.keys(customAttributes).length) {
      changed.custom_attributes = customAttributes;
    }
  }

  return changed;
};

export const rebaseSnapshotLockVersion = (snapshot, recordKey, current) => {
  if (!snapshot?.[recordKey] || !current) return snapshot;

  return {
    ...snapshot,
    [recordKey]: {
      ...snapshot[recordKey],
      lockVersion: current.lockVersion,
    },
  };
};
