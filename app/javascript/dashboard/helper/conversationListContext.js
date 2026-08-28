import wootConstants from 'dashboard/constants/globals';

export const CONVERSATION_LIST_CONTEXT_SETTINGS_KEY =
  'conversation_list_context_filters';

const validStatuses = new Set(Object.values(wootConstants.STATUS_TYPE));
const validSortOrders = new Set(Object.values(wootConstants.SORT_BY_TYPE));

const valueFromQuery = (query, snakeKey, camelKey) =>
  query?.[snakeKey] ?? query?.[camelKey];

export const conversationListContextKey = (query = {}, { folderId } = {}) => {
  if (folderId && String(folderId) !== '0') return `folder:${folderId}`;

  const crmStageId = valueFromQuery(query, 'crm_stage_id', 'crmStageId');
  if (crmStageId) return `crm-stage:${crmStageId}`;

  const appointmentStatus = valueFromQuery(
    query,
    'appointment_status',
    'appointmentStatus'
  );
  if (appointmentStatus) return `appointment:${appointmentStatus}`;

  const assigneeType =
    valueFromQuery(query, 'assignee_type', 'assigneeType') ||
    wootConstants.ASSIGNEE_TYPE.ALL;
  return `assignee:${assigneeType}`;
};

export const defaultStatusForConversationListContext = contextKey =>
  contextKey.startsWith('assignee:')
    ? wootConstants.STATUS_TYPE.OPEN
    : wootConstants.STATUS_TYPE.ALL;

export const conversationListContextState = (uiSettings, contextKey) => {
  const storedState =
    uiSettings?.[CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]?.[contextKey] || {};
  const defaultStatus = defaultStatusForConversationListContext(contextKey);

  return {
    status: validStatuses.has(storedState.status)
      ? storedState.status
      : defaultStatus,
    order_by: validSortOrders.has(storedState.order_by)
      ? storedState.order_by
      : wootConstants.SORT_BY_TYPE.LAST_ACTIVITY_AT_DESC,
  };
};

export const updatedConversationListContextSettings = (
  uiSettings,
  contextKey,
  updates = {}
) => ({
  ...(uiSettings?.[CONVERSATION_LIST_CONTEXT_SETTINGS_KEY] || {}),
  [contextKey]: {
    ...conversationListContextState(uiSettings, contextKey),
    ...updates,
  },
});
