import { FEATURE_FLAGS } from '../../../featureFlags';

export const WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES = [
  'general_settings_index',
  'auditlogs_list',
];

export const workspaceSettingsTabs = [
  {
    labelKey: 'SIDEBAR.ACCOUNT_SETTINGS',
    routeName: 'general_settings_index',
    activeOn: ['general_settings_index'],
  },
  {
    labelKey: 'SIDEBAR.AUDIT_LOGS',
    routeName: 'auditlogs_list',
    featureFlag: FEATURE_FLAGS.AUDIT_LOGS,
    activeOn: ['auditlogs_list'],
  },
];
