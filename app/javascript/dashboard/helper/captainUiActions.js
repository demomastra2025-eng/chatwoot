const SUPPORTED_ACTION_TYPES = new Set([
  'open_conversation',
  'open_contact',
  'open_task',
  'open_contacts',
  'open_tasks',
  'open_deals',
  'open_captain_settings',
]);

const DEFAULT_LABELS = {
  open_conversation: 'Open conversation',
  open_contact: 'Open contact',
  open_task: 'Open task',
  open_contacts: 'Open contacts',
  open_tasks: 'Open tasks',
  open_deals: 'Open deals',
  open_captain_settings: 'Open Captain settings',
};

const stripMarkup = value =>
  value
    .toString()
    .replace(/<[^>]*>/g, '')
    .replace(/[\r\n]+/g, ' ')
    .trim();

const actionTargetId = action =>
  action.target_id ??
  action.targetId ??
  action.entity_id ??
  action.entityId ??
  action.conversation_id ??
  action.conversationId ??
  action.contact_id ??
  action.contactId ??
  action.task_id ??
  action.taskId ??
  '';

export const normalizeCaptainUiActions = actions => {
  if (!Array.isArray(actions)) return [];

  return actions
    .filter(action => action && SUPPORTED_ACTION_TYPES.has(action.type))
    .slice(0, 5)
    .map(action => {
      const defaultLabel = DEFAULT_LABELS[action.type];
      const label = stripMarkup(action.label || defaultLabel).slice(0, 80);

      return {
        type: action.type,
        label: label || defaultLabel,
        targetId: actionTargetId(action).toString().trim(),
      };
    })
    .filter(action => action.label);
};

export const routeForCaptainUiAction = (action, accountId) => {
  switch (action.type) {
    case 'open_conversation':
      if (!action.targetId) return null;
      return {
        name: 'inbox_conversation',
        params: { accountId, conversation_id: action.targetId },
      };
    case 'open_contact':
      if (!action.targetId) return null;
      return {
        name: 'contacts_edit',
        params: { accountId, contactId: action.targetId },
      };
    case 'open_task':
      if (!action.targetId) return null;
      return {
        name: 'crm_tasks_index',
        params: { accountId },
        query: { taskId: action.targetId, source: 'captain_ui_action' },
      };
    case 'open_contacts':
      return { name: 'contacts_dashboard_index', params: { accountId } };
    case 'open_tasks':
      return { name: 'crm_tasks_index', params: { accountId } };
    case 'open_deals':
      return { name: 'crm_deals_index', params: { accountId } };
    case 'open_captain_settings':
      return { name: 'captain_settings_index', params: { accountId } };
    default:
      return null;
  }
};

export const executeCaptainUiAction = async (action, { router, accountId }) => {
  const targetRoute = routeForCaptainUiAction(action, accountId);
  if (!targetRoute) return false;

  await router.push(targetRoute);
  return true;
};
