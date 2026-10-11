// Turning off (or deleting) the main agent of an AI-enabled channel is refused
// by the server with 422 MAIN_AGENT_IN_USE and the ids of those channels. The
// exact JSON shape is still settling, so the parser accepts every shape the
// backend may send:
//   { code: 'MAIN_AGENT_IN_USE', inbox_ids: [5], message: '…' }
//   { error: 'MAIN_AGENT_IN_USE', inbox_ids: [5] }
//   { error_code: 'MAIN_AGENT_IN_USE', … }
//   { errors: [{ code: 'MAIN_AGENT_IN_USE', inbox_ids: [5] | inbox_id: 5 }] }
// It reads `error.response.data` (an axios error), so callers must use the API
// client directly: store actions flatten errors into a plain message.

export const MAIN_AGENT_IN_USE = 'MAIN_AGENT_IN_USE';

const isPlainObject = value =>
  Boolean(value) && typeof value === 'object' && !Array.isArray(value);

const errorPayload = error => {
  if (!error) return null;
  if (isPlainObject(error.response?.data)) return error.response.data;
  if (isPlainObject(error.data)) return error.data;
  return null;
};

const errorItems = data => (Array.isArray(data.errors) ? data.errors : []);

const isMainAgentInUseItem = item =>
  item === MAIN_AGENT_IN_USE ||
  (isPlainObject(item) &&
    [item.code, item.error, item.error_code].includes(MAIN_AGENT_IN_USE));

const hasMainAgentInUseCode = data =>
  [data.code, data.error, data.error_code].includes(MAIN_AGENT_IN_USE);

const toInboxIds = value => {
  const values = Array.isArray(value) ? value : [value];
  return values
    .filter(item => item !== null && item !== undefined && item !== '')
    .map(Number)
    .filter(id => Number.isInteger(id) && id > 0);
};

const itemInboxIds = item => {
  if (!isPlainObject(item)) return [];
  return [...toInboxIds(item.inbox_ids), ...toInboxIds(item.inbox_id)];
};

const firstString = (...values) =>
  values.find(value => typeof value === 'string' && value.trim()) || '';

/**
 * @param {unknown} error axios error (or anything else)
 * @returns {null | { inboxIds: number[], message: string }}
 */
export const parseMainAgentInUseError = error => {
  const data = errorPayload(error);
  if (!data) return null;

  const items = errorItems(data);
  const matchingItems = items.filter(isMainAgentInUseItem);
  const topLevelMatch = hasMainAgentInUseCode(data);
  if (!topLevelMatch && !matchingItems.length) return null;

  // With a top-level code every listed item belongs to this error; otherwise
  // only the items that carry the code do.
  const sourceItems = topLevelMatch ? items : matchingItems;
  const inboxIds = [
    ...toInboxIds(data.inbox_ids),
    ...sourceItems.flatMap(itemInboxIds),
  ];

  const itemMessage = sourceItems
    .map(item => (isPlainObject(item) ? item.message : ''))
    .find(message => typeof message === 'string' && message.trim());
  const errorText = data.error === MAIN_AGENT_IN_USE ? '' : data.error;

  return {
    inboxIds: Array.from(new Set(inboxIds)),
    message: firstString(data.message, itemMessage, errorText),
  };
};
