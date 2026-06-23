import { FEATURE_FLAGS } from '../../../featureFlags';

export const CONVERSATION_SETTINGS_ACTIVE_ROUTE_NAMES = [
  'conversation_workflow_index',
  'conversation_visibility_settings_index',
  'conversation_fields_settings_index',
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
    labelKey: 'ATTRIBUTES_MGMT.HEADER',
    routeName: 'conversation_fields_settings_index',
    featureFlag: FEATURE_FLAGS.CUSTOM_ATTRIBUTES,
    activeOn: ['conversation_fields_settings_index'],
  },
  {
    labelKey: 'CONVERSATION_WORKFLOW.TABS.VISIBILITY',
    routeName: 'conversation_visibility_settings_index',
    activeOn: ['conversation_visibility_settings_index'],
  },
  {
    labelKey: 'CONVERSATION_WORKFLOW.TABS.SLA',
    routeName: 'sla_list',
    activeOn: ['sla_wrapper', 'sla_list'],
  },
];
