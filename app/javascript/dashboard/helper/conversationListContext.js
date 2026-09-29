import wootConstants from 'dashboard/constants/globals';

// ui_settings key that stores the conversation list selection. The status is
// shared by every list context (the last chosen status is reopened
// everywhere), the sort order is remembered per left-sidebar context.
export const CONVERSATION_LIST_CONTEXT_SETTINGS_KEY =
  'conversation_list_context_filters';
export const CONVERSATION_LIST_GLOBAL_STATUS_KEY = '__global_status__';

// "All statuses" is not remembered. It stays in the URL of the current
// navigation only, so it never silently becomes the default of every list,
// count and sidebar unread request after a new login. The cost of status=all
// requests on production data has not been measured yet.
const rememberedStatuses = new Set(
  Object.values(wootConstants.STATUS_TYPE).filter(
    status => status !== wootConstants.STATUS_TYPE.ALL
  )
);
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
    status: rememberedStatuses.has(globalStatus)
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

  if (rememberedStatuses.has(status)) {
    nextSettings[CONVERSATION_LIST_GLOBAL_STATUS_KEY] = { status };
  }

  return nextSettings;
};
