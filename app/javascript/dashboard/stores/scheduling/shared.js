import camelcaseKeys from 'camelcase-keys';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

export const normalizePayload = data => {
  return camelcaseKeys(data?.payload || [], { deep: true });
};

export const normalizeMeta = data => {
  return camelcaseKeys(data?.meta || {}, { deep: true });
};

export const extractSchedulingError = error => {
  const payload = camelcaseKeys(error?.response?.data || {}, { deep: true });

  return {
    code: payload.code || 'UNKNOWN_ERROR',
    details: payload.details || null,
    message: payload.error || parseAPIErrorResponse(error),
    status: error?.response?.status || 500,
  };
};

export const upsertRecord = (records, record) => {
  const nextRecord = camelcaseKeys(record, { deep: true });
  const existingIndex = records.findIndex(item => item.id === nextRecord.id);

  if (existingIndex === -1) {
    return [nextRecord, ...records];
  }

  const nextRecords = [...records];
  nextRecords.splice(existingIndex, 1, nextRecord);
  return nextRecords;
};

export const removeRecord = (records, recordId) => {
  return records.filter(item => item.id !== Number(recordId));
};

export const compactPayload = payload => {
  return Object.entries(payload).reduce((result, [key, value]) => {
    if (value === '' || value === null || value === undefined) {
      return result;
    }

    if (Array.isArray(value) && value.length === 0) {
      return result;
    }

    result[key] = value;
    return result;
  }, {});
};

export const toNumeric = value => {
  if (value === '' || value === null || value === undefined) {
    return undefined;
  }

  const parsed = Number(value);
  return Number.isNaN(parsed) ? undefined : parsed;
};
