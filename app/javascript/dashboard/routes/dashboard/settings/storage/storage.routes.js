import { frontendURL } from '../../../../helper/URLHelper';

const SettingsWrapper = () => import('../SettingsWrapper.vue');
const StorageHome = () => import('./Index.vue');

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/storage'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'storage_settings_index',
          meta: {
            permissions: ['administrator'],
          },
          component: StorageHome,
        },
      ],
    },
  ],
};
