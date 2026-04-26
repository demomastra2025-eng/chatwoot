import { frontendURL } from '../../../../helper/URLHelper';
import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
const Index = () => import('./Index.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/billing'),
      meta: {
        permissions: ['administrator'],
        installationTypes: [INSTALLATION_TYPES.CLOUD],
      },
      component: SettingsWrapper,
      props: {
        headerTitle: 'BILLING_SETTINGS.TITLE',
        icon: 'credit-card-person',
        showNewButton: false,
      },
      children: [
        {
          path: '',
          name: 'billing_settings_index',
          component: Index,
          meta: {
            installationTypes: [INSTALLATION_TYPES.CLOUD],
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
