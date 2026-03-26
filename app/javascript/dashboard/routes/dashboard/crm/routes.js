import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';
import {
  CRM_DEAL_MANAGE_PERMISSION,
  CRM_DEAL_VIEW_PERMISSION,
  CRM_TASK_MANAGE_PERMISSION,
  CRM_TASK_VIEW_PERMISSION,
} from '../../../constants/permissions';
import {
  getUserPermissions,
  hasPermissions,
} from '../../../helper/permissionsHelper';
import store from '../../../store';

import CrmDealsPage from './pages/CrmDealsPage.vue';
import CrmTasksPage from './pages/CrmTasksPage.vue';

const dealsMeta = {
  featureFlag: FEATURE_FLAGS.CRM_DEALS,
  permissions: [
    'administrator',
    'agent',
    CRM_DEAL_VIEW_PERMISSION,
    CRM_DEAL_MANAGE_PERMISSION,
  ],
};

const tasksMeta = {
  featureFlag: FEATURE_FLAGS.CRM_TASKS,
  permissions: [
    'administrator',
    'agent',
    CRM_TASK_VIEW_PERMISSION,
    CRM_TASK_MANAGE_PERMISSION,
  ],
};

const crmLandingRouteName = accountId => {
  const userPermissions = getUserPermissions(
    store.getters.getCurrentUser,
    Number(accountId)
  );
  const dealsEnabled = store.getters['accounts/isFeatureEnabledonAccount'](
    accountId,
    FEATURE_FLAGS.CRM_DEALS
  );
  const tasksEnabled = store.getters['accounts/isFeatureEnabledonAccount'](
    accountId,
    FEATURE_FLAGS.CRM_TASKS
  );

  if (
    dealsEnabled &&
    hasPermissions(
      [
        'administrator',
        'agent',
        CRM_DEAL_VIEW_PERMISSION,
        CRM_DEAL_MANAGE_PERMISSION,
      ],
      userPermissions
    )
  ) {
    return 'crm_deals_index';
  }

  if (
    tasksEnabled &&
    hasPermissions(
      [
        'administrator',
        'agent',
        CRM_TASK_VIEW_PERMISSION,
        CRM_TASK_MANAGE_PERMISSION,
      ],
      userPermissions
    )
  ) {
    return 'crm_tasks_index';
  }

  return 'home';
};

export const routes = [
  {
    path: frontendURL('accounts/:accountId/crm'),
    redirect: to => ({
      name: crmLandingRouteName(to.params.accountId),
      params: to.params,
    }),
    meta: {
      permissions: [
        'administrator',
        'agent',
        CRM_DEAL_VIEW_PERMISSION,
        CRM_DEAL_MANAGE_PERMISSION,
        CRM_TASK_VIEW_PERMISSION,
        CRM_TASK_MANAGE_PERMISSION,
      ],
    },
  },
  {
    path: frontendURL('accounts/:accountId/crm/deals'),
    name: 'crm_deals_index',
    component: CrmDealsPage,
    meta: dealsMeta,
  },
  {
    path: frontendURL('accounts/:accountId/crm/tasks'),
    name: 'crm_tasks_index',
    component: CrmTasksPage,
    meta: tasksMeta,
  },
];
