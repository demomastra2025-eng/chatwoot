import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';
import {
  CRM_DEAL_VIEW_PERMISSIONS,
  CRM_TASK_VIEW_PERMISSIONS,
} from '../../../constants/permissions';
import { hasCrmViewPermission } from '../../../helper/permissionsHelper';
import store from '../../../store';

const CrmDealsPage = () => import('./pages/CrmDealsPage.vue');
const CrmTasksPage = () => import('./pages/CrmTasksPage.vue');
const dealsMeta = {
  featureFlag: FEATURE_FLAGS.CRM_DEALS,
  permissions: CRM_DEAL_VIEW_PERMISSIONS,
  crmResources: ['deals'],
};

const tasksMeta = {
  featureFlag: FEATURE_FLAGS.CRM_TASKS,
  permissions: CRM_TASK_VIEW_PERMISSIONS,
  crmResources: ['tasks'],
};

const crmLandingRouteName = accountId => {
  const user = store.getters.getCurrentUser;
  const dealsEnabled = store.getters['accounts/isFeatureEnabledonAccount'](
    accountId,
    FEATURE_FLAGS.CRM_DEALS
  );
  const tasksEnabled = store.getters['accounts/isFeatureEnabledonAccount'](
    accountId,
    FEATURE_FLAGS.CRM_TASKS
  );

  if (dealsEnabled && hasCrmViewPermission(user, accountId, 'deals')) {
    return 'crm_deals_index';
  }

  if (tasksEnabled && hasCrmViewPermission(user, accountId, 'tasks')) {
    return 'crm_tasks_index';
  }

  return 'home';
};

export const routes = [
  {
    path: frontendURL('accounts/:accountId/crm'),
    name: 'crm_index',
    // Route redirects run before global guards hydrate the current user.
    beforeEnter: to => ({
      name: crmLandingRouteName(to.params.accountId),
      params: to.params,
      query: to.query,
      hash: to.hash,
    }),
    meta: {
      permissions: [...CRM_DEAL_VIEW_PERMISSIONS, ...CRM_TASK_VIEW_PERMISSIONS],
      crmResources: ['deals', 'tasks'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/crm/deals'),
    redirect: to => ({
      name: 'crm_deals_index',
      params: to.params,
      query: to.query,
      hash: to.hash,
    }),
    meta: dealsMeta,
  },
  {
    path: frontendURL('accounts/:accountId/crm/tasks'),
    redirect: to => ({
      name: 'crm_tasks_index',
      params: to.params,
      query: to.query,
      hash: to.hash,
    }),
    meta: tasksMeta,
  },
  {
    path: frontendURL('accounts/:accountId/deals'),
    name: 'crm_deals_index',
    component: CrmDealsPage,
    meta: dealsMeta,
  },
  {
    path: frontendURL('accounts/:accountId/tasks'),
    name: 'crm_tasks_index',
    component: CrmTasksPage,
    meta: tasksMeta,
  },
];
