import ru from 'dashboard/i18n/locale/ru/crm.json';
import en from 'dashboard/i18n/locale/en/crm.json';
import kk from 'dashboard/i18n/locale/kk/crm.json';

// The task catalogs (types, outcomes, statuses) are seeded into the database
// by the backend. A row of a SYSTEM code is shown through i18n by code, so the
// label follows the language of the user; the stored name is shown only for
// entries the admin created or renamed. A stored name counts as "seeded" when
// it is the neutral seed name in any language (the same wording as these
// locales) or one of the English defaults the first release wrote.
const KINDS = {
  type: {
    legacy: {
      call: 'Call',
      meeting: 'Meeting',
      message: 'Message',
      task: 'Task',
      touch: 'Touch',
    },
    messages: locale => locale.CRM.TASKS.ACTIVITY_TYPE,
    key: 'CRM.TASKS.ACTIVITY_TYPE',
  },
  outcome: {
    legacy: {
      answered: 'Answered',
      busy: 'Busy',
      cancelled: 'Cancelled',
      completed: 'Completed',
      failed: 'Failed',
      held: 'Held',
      no_answer: 'No answer',
      no_show: 'No show',
      not_done: 'Not done',
      other: 'Other',
      rescheduled: 'Rescheduled',
      sent: 'Sent',
    },
    messages: locale => locale.CRM.TASKS.OUTCOME,
    key: 'CRM.TASKS.OUTCOME',
  },
  status: {
    legacy: {
      cancelled: 'Cancelled',
      done: 'Done',
      in_progress: 'In progress',
      todo: 'To do',
    },
    messages: locale => locale.CRM.TASKS.STATUS_NAMES,
    key: 'CRM.TASKS.STATUS_NAMES',
  },
};

const normalize = value =>
  String(value ?? '')
    .trim()
    .toLowerCase();

const seededNames = Object.fromEntries(
  Object.entries(KINDS).map(([kind, { legacy, messages }]) => [
    kind,
    Object.fromEntries(
      Object.keys(legacy).map(code => [
        code,
        new Set(
          [legacy[code], ...[ru, en, kk].map(locale => messages(locale)[code])]
            .filter(Boolean)
            .map(normalize)
        ),
      ])
    ),
  ])
);

const isSystemCode = (kind, code) =>
  Object.prototype.hasOwnProperty.call(KINDS[kind].legacy, code);

/**
 * Label of a task type / outcome / status row.
 * @param {'type'|'outcome'|'status'} kind
 * @param {{ code?: string, name?: string }} row
 * @param {Function} t vue-i18n translate function
 */
export const taskCatalogLabel = (kind, row, t) => {
  const code = row?.code;
  const name = (row?.name || '').trim();
  if (
    code &&
    isSystemCode(kind, code) &&
    (!name || seededNames[kind][code].has(normalize(name)))
  ) {
    return t(`${KINDS[kind].key}.${code}`);
  }

  return name || code || '';
};

export const taskTypeLabel = (row, t) => taskCatalogLabel('type', row, t);
export const taskOutcomeLabel = (row, t) => taskCatalogLabel('outcome', row, t);
export const taskStatusLabel = (row, t) => taskCatalogLabel('status', row, t);
