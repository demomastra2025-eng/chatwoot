// Backend texts of the reminder engine (the `Reminder` entity, historically
// called "touch") are English and say "touch". The UI never shows that word:
// known messages get localized text, anything else is shown with the
// reminder wording instead.

const KNOWN_MESSAGES = [
  {
    pattern: /open touch with the same content already exists/i,
    message: t => t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.DUPLICATE'),
  },
  {
    pattern: /only unsent open touches can be updated/i,
    message: t => t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.NOT_EDITABLE'),
  },
  {
    pattern: /only unsent delayed messages can be deleted/i,
    message: t => t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.NOT_DELETABLE'),
  },
  {
    pattern: /touch target is not deliverable/i,
    message: t => t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.TARGET_NOT_DELIVERABLE'),
  },
  {
    pattern: /touch target inbox is missing/i,
    message: t => t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.TARGET_INBOX_MISSING'),
  },
  {
    pattern: /touch target contact is missing/i,
    message: t => t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.TARGET_CONTACT_MISSING'),
  },
];

// "touch"/"touches" as a word or part of an identifier (apply_touch_plan).
const TOUCH_WORD = /(^|[^a-zA-Z])(touch(?:es)?)(?![a-zA-Z])/gi;

const matchCase = (source, replacement) =>
  source[0] === source[0].toUpperCase()
    ? replacement[0].toUpperCase() + replacement.slice(1)
    : replacement;

// «touch» → «reminder» in an English backend text.
export const withReminderWording = text =>
  String(text ?? '').replace(
    TOUCH_WORD,
    (_, prefix, word) =>
      prefix +
      matchCase(word, word.length > 'touch'.length ? 'reminders' : 'reminder')
  );

const knownMessage = (text, t) => {
  const known = KNOWN_MESSAGES.find(({ pattern }) => pattern.test(text));
  return known ? known.message(t) : '';
};

const backendErrorText = data => {
  if (!data || typeof data !== 'object') return '';

  const candidates = [
    data.error,
    data.message,
    ...(Array.isArray(data.errors) ? data.errors : []),
  ];
  return candidates.find(value => typeof value === 'string' && value) || '';
};

// Text for a failed reminder request (toast): a localized known message, the
// backend text in reminder wording, or the localized fallback.
export const reminderErrorMessage = (error, fallback, t) => {
  const text = error?.response
    ? backendErrorText(error.response.data)
    : error?.message || '';
  if (!text) return fallback;

  return knownMessage(text, t) || withReminderWording(text);
};

// A reminder's stored `last_error` for the analytics dialog.
export const reminderLastError = (lastError, t) => {
  if (!lastError) return '';

  return knownMessage(lastError, t) || withReminderWording(lastError);
};
