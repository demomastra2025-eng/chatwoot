// Locale files share some root sections. Preserve their nested keys while
// keeping the later file's value when the same translation is defined twice.
const isPlainObject = value =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const mergeObjects = (target, source) => {
  Object.entries(source).forEach(([key, value]) => {
    target[key] =
      isPlainObject(value) && isPlainObject(target[key])
        ? mergeObjects({ ...target[key] }, value)
        : value;
  });
  return target;
};

export const mergeLocaleParts = (...parts) =>
  parts.reduce((merged, part) => mergeObjects(merged, part), {});

// Older report copy is already translated, but some views use newer paths.
export const withReportAliases = messages => {
  messages.REPORT.DAILY_RESPONSE = messages.LABEL_REPORTS.DAILY_RESPONSE;
  const exportColumns = messages.REPORTS.LEADS.META_ADS.EXPORT_COLUMNS;
  Object.assign(exportColumns, {
    CHAT_ID: exportColumns.DISPLAY_ID,
    CHAT_URL: exportColumns.CONVERSATION_URL,
    CONTACT: exportColumns.CONTACT_NAME,
    CREATIVE: exportColumns.HEADLINE,
    EVENTS: exportColumns.EVENT_COUNT,
    FIRST_AT: exportColumns.FIRST_REFERRAL_AT,
    FORMAT: exportColumns.MEDIA_TYPE,
    INCOMING: exportColumns.INCOMING_COUNT,
    LAST_AT: exportColumns.LAST_REFERRAL_AT,
    OUTGOING: exportColumns.OUTGOING_COUNT,
    SOURCE_URLS: exportColumns.SOURCE_URL,
  });
  return messages;
};
