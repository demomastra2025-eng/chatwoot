// Turns Virtual PBX provisioning errors into messages an administrator can act on.
// The API returns `{ code, message, conflict? }` items in `payload.errors` (HTTP 200)
// and `{ code, error }` bodies for request-level failures (HTTP 4xx).

const ERROR_KEY_PREFIX = 'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ERRORS';
const NUMBER_CONFLICT_CODES = [
  'number_ref_taken',
  'display_phone_number_taken',
];
const PROFILE_ROW_PATTERN = /profiles\[(\d+)\]/;

const translate = (i18n, key, params) => {
  const { t, te } = i18n || {};
  if (typeof t !== 'function') return '';
  if (typeof te === 'function' && !te(key)) return '';

  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(key, params) || '';
};

const numberConflictText = (error, i18n) => {
  const conflict = error.conflict || {};
  const inboxId = conflict.inbox_id;

  if (inboxId && conflict.inbox_name) {
    return translate(i18n, `${ERROR_KEY_PREFIX}.NUMBER_TAKEN_BY_INBOX`, {
      name: conflict.inbox_name,
      id: inboxId,
    });
  }
  if (inboxId && conflict.same_account === false) {
    return translate(
      i18n,
      `${ERROR_KEY_PREFIX}.NUMBER_TAKEN_IN_OTHER_ACCOUNT`,
      {
        id: inboxId,
      }
    );
  }
  if (inboxId) {
    return translate(i18n, `${ERROR_KEY_PREFIX}.NUMBER_TAKEN_BY_INBOX_ID`, {
      id: inboxId,
    });
  }

  return translate(i18n, `${ERROR_KEY_PREFIX}.NUMBER_TAKEN`);
};

const profileRowNumber = message => {
  const match = PROFILE_ROW_PATTERN.exec(String(message || ''));
  return match ? Number(match[1]) + 1 : null;
};

export const virtualPbxErrorText = (error, i18n) => {
  if (!error) return '';
  if (typeof error === 'string') return error;

  const code = String(error.code || '').trim();
  if (NUMBER_CONFLICT_CODES.includes(code.toLowerCase())) {
    const conflictText = numberConflictText(error, i18n);
    if (conflictText) return conflictText;
  }

  const text = code
    ? translate(i18n, `${ERROR_KEY_PREFIX}.${code.toUpperCase()}`)
    : '';
  if (!text) return error.message || code;

  const row = profileRowNumber(error.message);
  if (!row) return text;

  return (
    translate(i18n, `${ERROR_KEY_PREFIX}.PROFILE_ROW`, {
      row,
      message: text,
    }) || text
  );
};

export const virtualPbxErrorsText = (errors, i18n) => {
  const texts = (Array.isArray(errors) ? errors : [])
    .map(error => virtualPbxErrorText(error, i18n))
    .filter(Boolean);

  return [...new Set(texts)].join(' ');
};

export const virtualPbxRequestErrorText = (
  requestError,
  i18n,
  fallback = ''
) => {
  const data = requestError?.response?.data || {};
  const payloadErrors = data.payload?.errors || data.errors;
  if (Array.isArray(payloadErrors) && payloadErrors.length) {
    const text = virtualPbxErrorsText(payloadErrors, i18n);
    if (text) return text;
  }

  if (data.code) {
    const text = translate(
      i18n,
      `${ERROR_KEY_PREFIX}.${String(data.code).toUpperCase()}`
    );
    if (text) return text;
  }

  return data.message || data.error || fallback || requestError?.message || '';
};
