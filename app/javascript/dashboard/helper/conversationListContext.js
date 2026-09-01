import wootConstants from 'dashboard/constants/globals';

export const CONVERSATION_LIST_CONTEXT_SETTINGS_KEY =
  'conversation_list_context_filters';
export const CONVERSATION_LIST_GLOBAL_STATUS_KEY = '__global_status__';

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

export const defaultStatusForConversationListContext = () =>
  wootConstants.STATUS_TYPE.OPEN;

export const conversationListContextState = (uiSettings, contextKey) => {
  const storedSettings =
    uiSettings?.[CONVERSATION_LIST_CONTEXT_SETTINGS_KEY] || {};
  const storedState = storedSettings[contextKey] || {};
  const globalStatus =
    storedSettings[CONVERSATION_LIST_GLOBAL_STATUS_KEY]?.status;

  return {
    status: validStatuses.has(globalStatus)
      ? globalStatus
      : defaultStatusForConversationListContext(),
    order_by: validSortOrders.has(storedState.order_by)
      ? storedState.order_by
      : wootConstants.SORT_BY_TYPE.LAST_ACTIVITY_AT_DESC,
  };
};

export const updatedConversationListContextSettings = (
  uiSettings,
  contextKey,
  updates = {}
) => {
  const storedSettings =
    uiSettings?.[CONVERSATION_LIST_CONTEXT_SETTINGS_KEY] || {};
  const { status, ...contextUpdates } = updates;
  const nextSettings = {
    ...storedSettings,
    [contextKey]: {
      ...(storedSettings[contextKey] || {}),
      ...contextUpdates,
    },
  };

  if (validStatuses.has(status)) {
    nextSettings[CONVERSATION_LIST_GLOBAL_STATUS_KEY] = { status };
  }

  return nextSettings;
};
