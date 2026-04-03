import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import store from '../../../../store';
import SettingsWrapper from '../SettingsWrapper.vue';
import Index from './Index.vue';
import TaskSettings from './TaskSettings.vue';

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
            if (
              to.query.action === 'create-task-status' &&
              hasCrmTasksEnabled(to.params.accountId)
            ) {
              next({
                name: 'crm_task_settings_index',
                params: to.params,
                query: to.query,
              });
              return;
            }

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
              path: frontendURL(`accounts/${to.params.accountId}/dashboard`),
            });
          },
        },
        {
          path: 'tasks',
          name: 'crm_task_settings_index',
          component: TaskSettings,
          meta: {
            permissions: [
              'administrator',
              'crm_settings_view',
              'crm_settings_manage',
            ],
          },
          beforeEnter: (to, _from, next) => {
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
              path: frontendURL(`accounts/${to.params.accountId}/dashboard`),
            });
          },
        },
      ],
    },
  ],
};
