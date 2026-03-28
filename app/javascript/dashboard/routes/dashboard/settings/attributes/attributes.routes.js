import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import { getUserPermissions } from '../../../../helper/permissionsHelper';
import store from '../../../../store';
import SettingsWrapper from '../SettingsWrapper.vue';
import AttributesHome from './Index.vue';

const hasLegacyAttributesAccess = accountId => {
  const permissions = getUserPermissions(
    store.getters.getCurrentUser,
    Number(accountId)
  );

  return (
    permissions.includes('administrator') &&
    store.getters['accounts/isFeatureEnabledonAccount'](
      accountId,
      FEATURE_FLAGS.CUSTOM_ATTRIBUTES
    )
  );
};

const hasCrmFieldAccess = accountId => {
  const permissions = getUserPermissions(
    store.getters.getCurrentUser,
    Number(accountId)
  );
  const hasCrmPermissions = [
    'administrator',
    'crm_settings_view',
    'crm_settings_manage',
  ].some(permission => permissions.includes(permission));

  return (
    hasCrmPermissions &&
    (store.getters['accounts/isFeatureEnabledonAccount'](
      accountId,
      FEATURE_FLAGS.CRM_DEALS
    ) ||
      store.getters['accounts/isFeatureEnabledonAccount'](
        accountId,
        FEATURE_FLAGS.CRM_TASKS
      ))
  );
};

const hasUnifiedAttributeAccess = accountId => {
  return hasLegacyAttributesAccess(accountId) || hasCrmFieldAccess(accountId);
};

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/custom-attributes'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          redirect: to => {
            return { name: 'attributes_list', params: to.params };
          },
        },
        {
          path: 'list',
          name: 'attributes_list',
          component: AttributesHome,
          meta: {
            permissions: [
              'administrator',
              'crm_settings_view',
              'crm_settings_manage',
            ],
          },
          beforeEnter: (to, _from, next) => {
            if (hasUnifiedAttributeAccess(to.params.accountId)) {
              next();
              return;
            }

            next({
              path: frontendURL(`accounts/${to.params.accountId}/dashboard`),
            });
          },
        },
      ],
    },
  ],
};
