import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import store from '../../../../store';
const SettingsTabsWrapper = () =>
  import('../components/SettingsTabsWrapper.vue');
const Index = () => import('./Index.vue');

const AttributesHome = () => import('../attributes/Index.vue');

const hasCrmDealsEnabled = accountId =>
  store.getters['accounts/isFeatureEnabledonAccount'](
    accountId,
    FEATURE_FLAGS.CRM_DEALS
  );

const hasCrmTasksEnabled = accountId =>
  store.getters['accounts/isFeatureEnabledonAccount'](
    accountId,
    FEATURE_FLAGS.CRM_TASKS
  );

const crmSettingsMeta = {
  permissions: ['administrator', 'crm_settings_view', 'crm_settings_manage'],
};

const dealSettingsTabs = [
  {
    labelKey: 'CRM.SETTINGS.PIPELINES.TITLE',
    routeName: 'crm_settings_index',
    activeOn: ['crm_settings_index'],
  },
  {
    labelKey: 'ATTRIBUTES_MGMT.HEADER',
    routeName: 'crm_deal_fields_settings_index',
    activeOn: ['crm_deal_fields_settings_index'],
  },
];

const taskSettingsTabs = [
  {
    labelKey: 'ATTRIBUTES_MGMT.HEADER',
    routeName: 'crm_task_settings_index',
    activeOn: ['crm_task_settings_index', 'crm_task_fields_settings_index'],
  },
];

const redirectToCrmLanding = (to, _from, next) => {
  if (hasCrmDealsEnabled(to.params.accountId)) {
    next();
    return;
  }

  if (hasCrmTasksEnabled(to.params.accountId)) {
    next({
      name: 'crm_task_settings_index',
      params: to.params,
      query: to.query,
    });
    return;
  }

  next({
    path: frontendURL(`accounts/${to.params.accountId}`),
  });
};

const requireCrmDeals = (to, _from, next) => {
  if (hasCrmDealsEnabled(to.params.accountId)) {
    next();
    return;
  }

  if (hasCrmTasksEnabled(to.params.accountId)) {
    next({
      name: 'crm_task_settings_index',
      params: to.params,
      query: to.query,
    });
    return;
  }

  next({
    path: frontendURL(`accounts/${to.params.accountId}`),
  });
};

const requireCrmTasks = (to, _from, next) => {
  if (hasCrmTasksEnabled(to.params.accountId)) {
    next();
    return;
  }

  if (hasCrmDealsEnabled(to.params.accountId)) {
    next({
      name: 'crm_settings_index',
      params: to.params,
      query: to.query,
    });
    return;
  }

  next({
    path: frontendURL(`accounts/${to.params.accountId}`),
  });
};

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/crm/tasks'),
      component: SettingsTabsWrapper,
      props: {
        tabs: taskSettingsTabs,
      },
      children: [
        {
          path: '',
          name: 'crm_task_settings_index',
          component: AttributesHome,
          props: {
            initialTab: 'task',
            showEntityTabs: false,
            tabs: ['task'],
          },
          meta: crmSettingsMeta,
          beforeEnter: requireCrmTasks,
        },
        {
          path: 'fields',
          name: 'crm_task_fields_settings_index',
          component: AttributesHome,
          props: {
            initialTab: 'task',
            showEntityTabs: false,
            tabs: ['task'],
          },
          meta: crmSettingsMeta,
          beforeEnter: requireCrmTasks,
        },
      ],
    },
    {
      path: frontendURL('accounts/:accountId/settings/crm'),
      component: SettingsTabsWrapper,
      props: {
        tabs: dealSettingsTabs,
      },
      children: [
        {
          path: '',
          name: 'crm_settings_index',
          component: Index,
          meta: crmSettingsMeta,
          beforeEnter: redirectToCrmLanding,
        },
        {
          path: 'fields',
          name: 'crm_deal_fields_settings_index',
          component: AttributesHome,
          props: {
            initialTab: 'deal',
            showEntityTabs: false,
            tabs: ['deal'],
          },
          meta: crmSettingsMeta,
          beforeEnter: requireCrmDeals,
        },
      ],
    },
  ],
};
