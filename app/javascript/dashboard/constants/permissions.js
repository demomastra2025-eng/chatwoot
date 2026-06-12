export const AVAILABLE_CUSTOM_ROLE_PERMISSIONS = [
  'conversation_manage',
  'conversation_unassigned_manage',
  'conversation_participating_manage',
  'contact_manage',
  'crm_deal_view',
  'crm_deal_manage',
  'crm_task_view',
  'crm_task_manage',
  'crm_settings_view',
  'crm_settings_manage',
  'report_manage',
  'knowledge_base_manage',
];

export const ROLES = ['agent', 'administrator'];

export const CONVERSATION_PERMISSIONS = [
  'conversation_manage',
  'conversation_unassigned_manage',
  'conversation_participating_manage',
];
export const CONVERSATION_ACCESS_PERMISSIONS = [
  ...ROLES,
  ...CONVERSATION_PERMISSIONS,
];
export const SCHEDULING_ACCESS_PERMISSIONS = [
  'administrator',
  'agent',
  'custom_role',
];

export const MANAGE_ALL_CONVERSATION_PERMISSIONS = 'conversation_manage';

export const CONVERSATION_UNASSIGNED_PERMISSIONS =
  'conversation_unassigned_manage';

export const CONVERSATION_PARTICIPATING_PERMISSIONS =
  'conversation_participating_manage';

export const CONTACT_PERMISSIONS = 'contact_manage';
export const CONTACT_ACCESS_PERMISSIONS = [...ROLES, CONTACT_PERMISSIONS];

export const REPORTS_PERMISSIONS = 'report_manage';

export const PORTAL_PERMISSIONS = 'knowledge_base_manage';

export const CRM_DEAL_VIEW_PERMISSION = 'crm_deal_view';
export const CRM_DEAL_MANAGE_PERMISSION = 'crm_deal_manage';
export const CRM_TASK_VIEW_PERMISSION = 'crm_task_view';
export const CRM_TASK_MANAGE_PERMISSION = 'crm_task_manage';
export const CRM_SETTINGS_VIEW_PERMISSION = 'crm_settings_view';
export const CRM_SETTINGS_MANAGE_PERMISSION = 'crm_settings_manage';

export const CRM_DEAL_VIEW_PERMISSIONS = [
  ...ROLES,
  CRM_DEAL_VIEW_PERMISSION,
  CRM_DEAL_MANAGE_PERMISSION,
];
export const CRM_DEAL_MANAGE_PERMISSIONS = [
  ...ROLES,
  CRM_DEAL_MANAGE_PERMISSION,
];
export const CRM_TASK_VIEW_PERMISSIONS = [
  ...ROLES,
  CRM_TASK_VIEW_PERMISSION,
  CRM_TASK_MANAGE_PERMISSION,
];
export const CRM_TASK_MANAGE_PERMISSIONS = [
  ...ROLES,
  CRM_TASK_MANAGE_PERMISSION,
];

export const ASSIGNEE_TYPE_TAB_PERMISSIONS = {
  me: {
    count: 'mineCount',
    unreadCount: 'mineUnreadCount',
    permissions: [...ROLES, ...CONVERSATION_PERMISSIONS],
  },
  unassigned: {
    count: 'unAssignedCount',
    unreadCount: 'unAssignedUnreadCount',
    permissions: [
      ...ROLES,
      MANAGE_ALL_CONVERSATION_PERMISSIONS,
      CONVERSATION_UNASSIGNED_PERMISSIONS,
    ],
  },
  all: {
    count: 'allCount',
    unreadCount: 'allUnreadCount',
    permissions: [
      ...ROLES,
      MANAGE_ALL_CONVERSATION_PERMISSIONS,
      CONVERSATION_PARTICIPATING_PERMISSIONS,
    ],
  },
};
