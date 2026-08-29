import { frontendURL } from '../../../../helper/URLHelper';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
const Index = () => import('./Index.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/captain/usage'),
      component: SettingsWrapper,
      meta: {
        permissions: ['administrator'],
        featureFlag: FEATURE_FLAGS.CAPTAIN,
        installationTypes: [
          INSTALLATION_TYPES.ENTERPRISE,
          INSTALLATION_TYPES.CLOUD,
        ],
      },
      children: [
        {
          path: '',
          name: 'captain_usage_index',
          component: Index,
          props: { section: 'usage' },
        },
      ],
    },
  ],
};
