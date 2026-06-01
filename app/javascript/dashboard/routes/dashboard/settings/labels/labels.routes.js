import { frontendURL } from '../../../../helper/URLHelper';

const SettingsWrapper = () => import('../SettingsWrapper.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/labels'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'labels_wrapper',
          meta: {
            permissions: ['administrator'],
          },
          redirect: to => {
            return { name: 'contact_tags_settings_index', params: to.params };
          },
        },
        {
          path: 'list',
          name: 'labels_list',
          meta: {
            permissions: ['administrator'],
          },
          redirect: to => {
            return { name: 'contact_tags_settings_index', params: to.params };
          },
        },
      ],
    },
  ],
};
