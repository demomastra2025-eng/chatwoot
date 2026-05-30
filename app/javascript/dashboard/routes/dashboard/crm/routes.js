import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';
import {
  CRM_DEAL_VIEW_PERMISSIONS,
  CRM_TASK_VIEW_PERMISSIONS,
} from '../../../constants/permissions';
import {
  getUserPermissions,
  hasPermissions,
} from '../../../helper/permissionsHelper';
import store from '../../../store';

const CrmDealsPage = () => import('./pages/CrmDealsPage.vue');
const CrmTasksPage = () => import('./pages/CrmTasksPage.vue');
const dealsMeta = {
  featureFlag: FEATURE_FLAGS.CRM_DEALS,
  permissions: CRM_DEAL_VIEW_PERMISSIONS,
};

const tasksMeta = {
  featureFlag: FEATURE_FLAGS.CRM_TASKS,
  permissions: CRM_TASK_VIEW_PERMISSIONS,
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
    hasPermissions(CRM_DEAL_VIEW_PERMISSIONS, userPermissions)
  ) {
    return 'crm_deals_index';
  }

  if (
    tasksEnabled &&
    hasPermissions(CRM_TASK_VIEW_PERMISSIONS, userPermissions)
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
      permissions: [...CRM_DEAL_VIEW_PERMISSIONS, ...CRM_TASK_VIEW_PERMISSIONS],
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
