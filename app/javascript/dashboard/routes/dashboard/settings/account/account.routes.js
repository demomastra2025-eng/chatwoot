import { frontendURL } from '../../../../helper/URLHelper';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
const Index = () => import('./Index.vue');
const Scheduling = () => import('./Scheduling.vue');
const SettingsWrapper = () => import('../SettingsWrapper.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/general'),
      meta: {
        permissions: ['administrator'],
      },
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'general_settings_index',
          component: Index,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
    {
      path: frontendURL('accounts/:accountId/settings/scheduling'),
      meta: {
        permissions: ['administrator'],
        featureFlag: FEATURE_FLAGS.SCHEDULING,
      },
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'scheduling_settings_index',
          component: Scheduling,
          meta: {
            permissions: ['administrator'],
            featureFlag: FEATURE_FLAGS.SCHEDULING,
          },
        },
      ],
    },
  ],
};
