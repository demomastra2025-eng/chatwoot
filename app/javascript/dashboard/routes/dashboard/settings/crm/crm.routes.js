import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import store from '../../../../store';
import SettingsWrapper from '../SettingsWrapper.vue';
import Index from './Index.vue';

const hasCrmRuntimeEnabled = accountId => {
  return (
    store.getters['accounts/isFeatureEnabledonAccount'](
      accountId,
      FEATURE_FLAGS.CRM_DEALS
    ) ||
    store.getters['accounts/isFeatureEnabledonAccount'](
      accountId,
      FEATURE_FLAGS.CRM_TASKS
    )
  );
};

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/crm'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'crm_settings_index',
          component: Index,
          meta: {
            permissions: [
              'administrator',
              'crm_settings_view',
              'crm_settings_manage',
            ],
          },
          beforeEnter: (to, _from, next) => {
            if (hasCrmRuntimeEnabled(to.params.accountId)) {
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
