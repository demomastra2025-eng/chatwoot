import camelcaseKeys from 'camelcase-keys';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import { preserveCustomAttributeKeys } from 'dashboard/utils/preserveCustomAttributeKeys';

const normalizeRecord = payload => {
  return preserveCustomAttributeKeys(
    payload,
    camelcaseKeys(payload, { deep: true })
  );
};

export const normalizePayload = data => normalizeRecord(data?.payload || []);

export const normalizeMeta = data =>
  camelcaseKeys(data?.meta || {}, { deep: true });

export const extractCrmError = error => {
  const payload = camelcaseKeys(error?.response?.data || {}, { deep: true });

  return {
    code: payload.code || 'UNKNOWN_ERROR',
    details: payload.details || null,
    message: payload.error || parseAPIErrorResponse(error),
    status: error?.response?.status || 500,
  };
};

const resolveCrmErrorPayload = error => {
  if (error?.code && error?.message) {
    return error;
  }

  return extractCrmError(error);
};

const resolveMissingFieldLabels = payload => {
  return (payload.details?.missingFields || [])
    .map(field => field?.label)
    .filter(Boolean)
    .join(', ');
};

const translateOrFallback = (t, key, fallback, params = {}) => {
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  const translated = t(key, params);
  return translated === key ? fallback : translated;
};

export const formatCrmErrorMessage = (error, t) => {
  const payload = resolveCrmErrorPayload(error);
  const missingFields = resolveMissingFieldLabels(payload);

  switch (payload.code) {
    case 'DUPLICATE_EXTERNAL_REF':
      return t('CRM.ERRORS.DUPLICATE_EXTERNAL_REF');
    case 'DUPLICATE_IDEMPOTENCY_KEY':
      return t('CRM.ERRORS.DUPLICATE_IDEMPOTENCY_KEY');
    case 'DEAL_STAGE_REQUIRES_FIELDS':
      return translateOrFallback(
        t,
        'CRM.ERRORS.DEAL_STAGE_REQUIRES_FIELDS',
        payload.message,
        { fields: missingFields }
      );
    case 'FEATURE_DISABLED':
      return t('CRM.ERRORS.FEATURE_DISABLED');
    case 'NOT_FOUND':
      return t('CRM.ERRORS.NOT_FOUND');
    case 'PIPELINE_HAS_DEALS':
      return t('CRM.ERRORS.PIPELINE_HAS_DEALS');
    case 'PIPELINE_MUST_BE_ARCHIVED':
      return t('CRM.ERRORS.PIPELINE_MUST_BE_ARCHIVED');
    case 'STAGE_HAS_DEALS':
      return t('CRM.ERRORS.STAGE_HAS_DEALS');
    case 'STANDARD_STAGE_LOCKED':
      return t('CRM.ERRORS.STANDARD_STAGE_LOCKED');
    case 'TASK_STATUS_HAS_TASKS':
      return t('CRM.ERRORS.TASK_STATUS_HAS_TASKS');
    case 'TASK_STATUS_REQUIRES_FIELDS':
      return translateOrFallback(
        t,
        'CRM.ERRORS.TASK_STATUS_REQUIRES_FIELDS',
        payload.message,
        { fields: missingFields }
      );
    case 'STALE_RECORD':
      return t('CRM.ERRORS.STALE_RECORD');
    case 'VALIDATION_ERROR':
      return t('CRM.ERRORS.VALIDATION_ERROR');
    default:
      break;
  }

  return payload.message || t('CRM.ERRORS.GENERIC');
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

export const removeRecord = (records, recordId) =>
  records.filter(item => item.id !== Number(recordId));

export const upsertRecord = (records, record) => {
  const normalizedRecord = normalizeRecord(record);
  const existingIndex = records.findIndex(
    item => item.id === normalizedRecord.id
  );

  if (existingIndex === -1) {
    return [normalizedRecord, ...records];
  }

  const nextRecords = [...records];
  nextRecords.splice(existingIndex, 1, normalizedRecord);
  return nextRecords;
};
