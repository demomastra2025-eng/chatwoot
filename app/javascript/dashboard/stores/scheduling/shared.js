import camelcaseKeys from 'camelcase-keys';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import { preserveCustomAttributeKeys } from 'dashboard/utils/preserveCustomAttributeKeys';

const ERROR_KEY_BY_CODE = {
  APPOINTMENT_DELETE_REQUIRES_CANCELLED:
    'SCHEDULING.ERRORS.APPOINTMENT_DELETE_REQUIRES_CANCELLED',
  APPOINTMENT_NOT_FOUND: 'SCHEDULING.ERRORS.APPOINTMENT_NOT_FOUND',
  BLOCKED_BY_BREAK: 'SCHEDULING.ERRORS.BLOCKED_BY_BREAK',
  BLOCKED_BY_HOLIDAY: 'SCHEDULING.ERRORS.BLOCKED_BY_HOLIDAY',
  BLOCKED_BY_VACATION: 'SCHEDULING.ERRORS.BLOCKED_BY_VACATION',
  DUPLICATE_EXTERNAL_REF: 'SCHEDULING.ERRORS.DUPLICATE_EXTERNAL_REF',
  DUPLICATE_IDEMPOTENCY_KEY: 'SCHEDULING.ERRORS.DUPLICATE_IDEMPOTENCY_KEY',
  EXPENSE_NOT_FOUND: 'SCHEDULING.ERRORS.EXPENSE_NOT_FOUND',
  INVALID_IIN: 'SCHEDULING.ERRORS.INVALID_IIN',
  OUTSIDE_WORKING_HOURS: 'SCHEDULING.ERRORS.OUTSIDE_WORKING_HOURS',
  RESOURCE_HAS_APPOINTMENTS: 'SCHEDULING.ERRORS.RESOURCE_HAS_APPOINTMENTS',
  RESOURCE_NOT_AVAILABLE_FOR_SCHEDULING:
    'SCHEDULING.ERRORS.RESOURCE_NOT_AVAILABLE_FOR_SCHEDULING',
  SERVICE_NOT_AVAILABLE_FOR_RESOURCE:
    'SCHEDULING.ERRORS.SERVICE_NOT_AVAILABLE_FOR_RESOURCE',
  SLOT_CONFLICT: 'SCHEDULING.ERRORS.SLOT_CONFLICT',
};

const ERROR_KEY_BY_MESSAGE = {
  'Appointment is outside working hours':
    'SCHEDULING.ERRORS.OUTSIDE_WORKING_HOURS',
  'Only cancelled appointments can be deleted':
    'SCHEDULING.ERRORS.APPOINTMENT_DELETE_REQUIRES_CANCELLED',
  'Appointment must fit into one local day':
    'SCHEDULING.ERRORS.SINGLE_DAY_REQUIRED',
  'Appointment overlaps blocked time': 'SCHEDULING.ERRORS.BLOCKED_BY_VACATION',
  'Appointment overlaps resource break': 'SCHEDULING.ERRORS.BLOCKED_BY_BREAK',
  'Cancelled payments cannot be updated':
    'SCHEDULING.ERRORS.CANCELLED_PAYMENTS_LOCKED',
  "Cannot cancel payment after the resource's expense has been paid":
    'SCHEDULING.ERRORS.CANNOT_CANCEL_PAID_EXPENSE',
  'End date must be greater than start date':
    'SCHEDULING.ERRORS.END_BEFORE_START',
  'Invalid IIN': 'SCHEDULING.ERRORS.INVALID_IIN',
  'No working rules configured for this day':
    'SCHEDULING.ERRORS.NO_WORKING_RULES',
  'Payment amount exceeds remaining balance':
    'SCHEDULING.ERRORS.PAYMENT_AMOUNT_EXCEEDS_BALANCE',
  'Payment amount must be greater than 0':
    'SCHEDULING.ERRORS.PAYMENT_AMOUNT_REQUIRED',
  'Specialist with appointments cannot be deleted':
    'SCHEDULING.ERRORS.RESOURCE_HAS_APPOINTMENTS',
  'Specialist with active appointments cannot be deleted':
    'SCHEDULING.ERRORS.RESOURCE_HAS_APPOINTMENTS',
  'Specialist is not available for scheduling':
    'SCHEDULING.ERRORS.RESOURCE_NOT_AVAILABLE_FOR_SCHEDULING',
  'Scheduling finance is not enabled for this account':
    'SCHEDULING.ERRORS.FINANCE_DISABLED',
  'Scheduling is not enabled for this account':
    'SCHEDULING.ERRORS.FEATURE_DISABLED',
  'Service is not available for the selected resource':
    'SCHEDULING.ERRORS.SERVICE_NOT_AVAILABLE_FOR_RESOURCE',
  'Set service_amount before adding payment':
    'SCHEDULING.ERRORS.SET_SERVICE_AMOUNT_FIRST',
  'Slot is already occupied': 'SCHEDULING.ERRORS.SLOT_CONFLICT',
  'Total received amount cannot exceed service_amount':
    'SCHEDULING.ERRORS.TOTAL_RECEIVED_EXCEEDS_SERVICE_AMOUNT',
  'total received amount cannot exceed service_amount':
    'SCHEDULING.ERRORS.TOTAL_RECEIVED_EXCEEDS_SERVICE_AMOUNT',
  'client_name is required': 'SCHEDULING.ERRORS.CLIENT_NAME_REQUIRED',
  'resource_id is required for service prices':
    'SCHEDULING.ERRORS.RESOURCE_REQUIRED_FOR_SERVICE_PRICE',
  'service_amount is required and must be greater than 0':
    'SCHEDULING.ERRORS.SERVICE_AMOUNT_REQUIRED',
  'settlement_amount cannot be less than the total of recorded payments':
    'SCHEDULING.ERRORS.SETTLEMENT_BELOW_RECORDED_PAYMENTS',
};

const ERROR_FIELD_KEY_BY_NAME = {
  break_end_minute: 'SCHEDULING.EXCEPTIONS.BREAK_END',
  break_start_minute: 'SCHEDULING.EXCEPTIONS.BREAK_START',
  client_name: 'SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME',
  ends_at: 'SCHEDULING.APPOINTMENT_FORM.ENDS_AT',
  from: 'SCHEDULING.KASSA.FROM',
  prepaid_amount: 'SCHEDULING.APPOINTMENT_FORM.PREPAID_AMOUNT',
  resource_id: 'SCHEDULING.APPOINTMENT_FORM.RESOURCE',
  service_amount: 'SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT',
  starts_at: 'SCHEDULING.APPOINTMENT_FORM.STARTS_AT',
  to: 'SCHEDULING.KASSA.TO',
};

export const normalizePayload = data => {
  return preserveCustomAttributeKeys(
    data?.payload || [],
    camelcaseKeys(data?.payload || [], { deep: true })
  );
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

const resolveSchedulingErrorPayload = error => {
  if (error?.code && error?.message) {
    return error;
  }

  return extractSchedulingError(error);
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

const fallbackFieldLabel = field => {
  return field
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());
};

const resolveFieldLabel = (field, t) => {
  const translationKey = ERROR_FIELD_KEY_BY_NAME[field];
  if (!translationKey) {
    return fallbackFieldLabel(field);
  }

  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  const translated = t(translationKey);
  return translated === translationKey ? fallbackFieldLabel(field) : translated;
};

export const formatSchedulingErrorMessage = (error, t) => {
  const payload = resolveSchedulingErrorPayload(error);
  const missingFields = resolveMissingFieldLabels(payload);

  if (payload.code === 'APPOINTMENT_PAYMENT_REQUIRES_FIELDS') {
    return translateOrFallback(
      t,
      'SCHEDULING.ERRORS.APPOINTMENT_PAYMENT_REQUIRES_FIELDS',
      payload.message,
      { fields: missingFields }
    );
  }

  const directKey =
    ERROR_KEY_BY_CODE[payload.code] || ERROR_KEY_BY_MESSAGE[payload.message];

  if (directKey) {
    return translateOrFallback(
      t,
      directKey,
      payload.message || t('SCHEDULING.ERRORS.GENERIC')
    );
  }

  const requiredMatch = payload.message?.match(/^([a-z_]+) is required$/);
  if (requiredMatch) {
    return t('SCHEDULING.ERRORS.FIELD_REQUIRED', {
      field: resolveFieldLabel(requiredMatch[1], t),
    });
  }

  const datetimeMatch = payload.message?.match(
    /^([a-z_]+) must be a valid datetime$/
  );
  if (datetimeMatch) {
    return t('SCHEDULING.ERRORS.FIELD_INVALID_DATETIME', {
      field: resolveFieldLabel(datetimeMatch[1], t),
    });
  }

  const dateMatch = payload.message?.match(/^([a-z_]+) must be YYYY-MM-DD$/);
  if (dateMatch) {
    return t('SCHEDULING.ERRORS.FIELD_INVALID_DATE', {
      field: resolveFieldLabel(dateMatch[1], t),
    });
  }

  const integerMatch = payload.message?.match(/^([a-z_]+) must be an integer$/);
  if (integerMatch) {
    return t('SCHEDULING.ERRORS.FIELD_INVALID_INTEGER', {
      field: resolveFieldLabel(integerMatch[1], t),
    });
  }

  return payload.message || t('SCHEDULING.ERRORS.GENERIC');
};

export const upsertRecord = (records, record) => {
  const nextRecord = preserveCustomAttributeKeys(
    record,
    camelcaseKeys(record, { deep: true })
  );
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
