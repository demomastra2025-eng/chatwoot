import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import { getUserPermissions } from '../../../../helper/permissionsHelper';
import store from '../../../../store';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
const SettingsTabsWrapper = () =>
  import('../components/SettingsTabsWrapper.vue');
const AttributesHome = () => import('./Index.vue');
const LabelsHome = () => import('../labels/Index.vue');

const legacyFieldSettingsMeta = {
  permissions: ['administrator'],
  featureFlag: FEATURE_FLAGS.CUSTOM_ATTRIBUTES,
};

const contactSettingsTabs = [
  {
    labelKey: 'ATTRIBUTES_MGMT.HEADER',
    routeName: 'contact_fields_settings_index',
    activeOn: ['contact_fields_settings_index'],
    featureFlag: FEATURE_FLAGS.CUSTOM_ATTRIBUTES,
  },
  {
    labelKey: 'SIDEBAR.LABELS',
    routeName: 'contact_tags_settings_index',
    activeOn: ['contact_tags_settings_index', 'labels_wrapper', 'labels_list'],
  },
];

const companySettingsTabs = [
  {
    labelKey: 'ATTRIBUTES_MGMT.HEADER',
    routeName: 'company_fields_settings_index',
    activeOn: ['company_fields_settings_index'],
  },
];

const hasFeature = (accountId, featureFlag) =>
  store.getters['accounts/isFeatureEnabledonAccount'](accountId, featureFlag);

const hasLegacyAttributesAccess = accountId => {
  const permissions = getUserPermissions(
    store.getters.getCurrentUser,
    Number(accountId)
  );

  return (
    permissions.includes('administrator') &&
    hasFeature(accountId, FEATURE_FLAGS.CUSTOM_ATTRIBUTES)
  );
};

const hasManagedFieldAccess = accountId => {
  const permissions = getUserPermissions(
    store.getters.getCurrentUser,
    Number(accountId)
  );
  const isAdmin = permissions.includes('administrator');
  const hasCrmPermissions = [
    'administrator',
    'crm_settings_view',
    'crm_settings_manage',
  ].some(permission => permissions.includes(permission));

  return (
    (hasCrmPermissions &&
      (hasFeature(accountId, FEATURE_FLAGS.CRM_DEALS) ||
        hasFeature(accountId, FEATURE_FLAGS.CRM_TASKS))) ||
    (isAdmin && hasFeature(accountId, FEATURE_FLAGS.SCHEDULING))
  );
};

const legacyAttributesFallbackRoute = to => {
  const accountId = to.params.accountId;

  if (hasLegacyAttributesAccess(accountId)) {
    return { name: 'conversation_fields_settings_index', params: to.params };
  }

  if (hasManagedFieldAccess(accountId)) {
    if (hasFeature(accountId, FEATURE_FLAGS.CRM_DEALS)) {
      return { name: 'crm_deal_fields_settings_index', params: to.params };
    }

    if (hasFeature(accountId, FEATURE_FLAGS.CRM_TASKS)) {
      return { name: 'crm_task_fields_settings_index', params: to.params };
    }

    if (hasFeature(accountId, FEATURE_FLAGS.SCHEDULING)) {
      return { name: 'scheduling_fields_settings_index', params: to.params };
    }
  }

  return {
    path: frontendURL(`accounts/${accountId}/dashboard`),
  };
};

const requireLegacyAttributes = (to, _from, next) => {
  if (hasLegacyAttributesAccess(to.params.accountId)) {
    next();
    return;
  }

  next({
    path: frontendURL(`accounts/${to.params.accountId}/dashboard`),
  });
};

const requireCompanyAttributes = (to, _from, next) => {
  if (
    hasLegacyAttributesAccess(to.params.accountId) &&
    hasFeature(to.params.accountId, FEATURE_FLAGS.COMPANIES)
  ) {
    next();
    return;
  }

  next({
    path: frontendURL(`accounts/${to.params.accountId}/dashboard`),
  });
};

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/custom-attributes'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          redirect: to => legacyAttributesFallbackRoute(to),
        },
        {
          path: 'list',
          name: 'attributes_list',
          redirect: to => legacyAttributesFallbackRoute(to),
        },
      ],
    },
    {
      path: frontendURL('accounts/:accountId/settings/contacts'),
      component: SettingsTabsWrapper,
      props: {
        tabs: contactSettingsTabs,
      },
      children: [
        {
          path: '',
          redirect: to => ({
            name: hasLegacyAttributesAccess(to.params.accountId)
              ? 'contact_fields_settings_index'
              : 'contact_tags_settings_index',
            params: to.params,
          }),
        },
        {
          path: 'fields',
          name: 'contact_fields_settings_index',
          component: AttributesHome,
          props: {
            initialTab: 'contact_attribute',
            showEntityTabs: false,
            tabs: ['contact_attribute'],
          },
          meta: legacyFieldSettingsMeta,
          beforeEnter: requireLegacyAttributes,
        },
        {
          path: 'tags',
          name: 'contact_tags_settings_index',
          component: LabelsHome,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
    {
      path: frontendURL('accounts/:accountId/settings/companies'),
      component: SettingsTabsWrapper,
      props: {
        tabs: companySettingsTabs,
      },
      children: [
        {
          path: '',
          redirect: to => ({
            name: 'company_fields_settings_index',
            params: to.params,
          }),
        },
        {
          path: 'fields',
          name: 'company_fields_settings_index',
          component: AttributesHome,
          props: {
            initialTab: 'company_attribute',
            showEntityTabs: false,
            tabs: ['company_attribute'],
          },
          meta: {
            ...legacyFieldSettingsMeta,
            featureFlag: FEATURE_FLAGS.COMPANIES,
          },
          beforeEnter: requireCompanyAttributes,
        },
      ],
    },
  ],
};
