export const CONVERSATION_SETTINGS_ACTIVE_ROUTE_NAMES = [
  'conversation_workflow_index',
  'sla_wrapper',
  'sla_list',
];

export const conversationSettingsTabs = [
  {
    labelKey: 'CONVERSATION_WORKFLOW.TABS.CLOSURE',
    routeName: 'conversation_workflow_index',
    activeOn: ['conversation_workflow_index'],
  },
  {
    labelKey: 'CONVERSATION_WORKFLOW.TABS.SLA',
    routeName: 'sla_list',
    activeOn: ['sla_wrapper', 'sla_list'],
  },
];
