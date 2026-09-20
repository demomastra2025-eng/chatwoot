import { extractCrmError } from 'dashboard/stores/crm/shared';
import { reactive } from 'vue';

const initialConflictState = () => ({
  active: false,
  hasAuthoritative: false,
  isReloading: false,
  reloadFailed: false,
});

export const createCrmConflictStateMachine = () => {
  const state = reactive(initialConflictState());
  let generation = 0;

  const reset = () => {
    generation += 1;
    Object.assign(state, initialConflictState());
  };

  const markStale = () => {
    state.active = true;
    state.hasAuthoritative = false;
  };

  const reload = async ({
    applyAuthoritative,
    isCurrentRecord,
    loadAuthoritative,
    recordId: requestedRecordId,
  }) => {
    const recordId = Number(requestedRecordId);
    if (!recordId || state.isReloading) return false;

    generation += 1;
    const requestGeneration = generation;
    markStale();
    state.isReloading = true;
    state.reloadFailed = false;

    const isCurrent = () =>
      requestGeneration === generation &&
      isCurrentRecord(recordId) &&
      state.active;

    try {
      const authoritative = await loadAuthoritative(recordId);
      if (!isCurrent()) return false;
      applyAuthoritative(authoritative, recordId);
      state.hasAuthoritative = true;
      return true;
    } catch {
      if (!isCurrent()) return false;
      state.hasAuthoritative = false;
      state.reloadFailed = true;
      return true;
    } finally {
      if (requestGeneration === generation) state.isReloading = false;
    }
  };

  return { markStale, reload, reset, state };
};

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
