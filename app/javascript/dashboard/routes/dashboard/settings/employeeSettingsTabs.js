import { FEATURE_FLAGS } from '../../../featureFlags';

export const EMPLOYEE_SETTINGS_ACTIVE_ROUTE_NAMES = [
  'agent_list',
  'settings_teams_list',
  'settings_teams_new',
  'settings_teams_finish',
  'settings_teams_add_agents',
  'settings_teams_show',
  'settings_teams_edit',
  'settings_teams_edit_members',
  'settings_teams_edit_finish',
  'custom_roles_list',
  'assignment_policy_index',
  'agent_assignment_policy_index',
  'agent_assignment_policy_create',
  'agent_assignment_policy_edit',
  'agent_capacity_policy_index',
  'agent_capacity_policy_create',
  'agent_capacity_policy_edit',
];

export const employeeSettingsTabs = [
  {
    labelKey: 'EMPLOYEE_SETTINGS.TABS.EMPLOYEES',
    routeName: 'agent_list',
    activeOn: ['agent_list'],
  },
  {
    labelKey: 'EMPLOYEE_SETTINGS.TABS.TEAM',
    routeName: 'settings_teams_list',
    activeOn: [
      'settings_teams_list',
      'settings_teams_new',
      'settings_teams_finish',
      'settings_teams_add_agents',
      'settings_teams_show',
      'settings_teams_edit',
      'settings_teams_edit_members',
      'settings_teams_edit_finish',
    ],
  },
  {
    labelKey: 'EMPLOYEE_SETTINGS.TABS.ROLES',
    routeName: 'custom_roles_list',
    activeOn: ['custom_roles_list'],
  },
  {
    labelKey: 'EMPLOYEE_SETTINGS.TABS.ASSIGNMENT',
    routeName: 'assignment_policy_index',
    featureFlag: FEATURE_FLAGS.ASSIGNMENT_V2,
    activeOn: [
      'assignment_policy_index',
      'agent_assignment_policy_index',
      'agent_assignment_policy_create',
      'agent_assignment_policy_edit',
      'agent_capacity_policy_index',
      'agent_capacity_policy_create',
      'agent_capacity_policy_edit',
    ],
  },
];
