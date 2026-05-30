import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import { CONVERSATION_ACCESS_PERMISSIONS } from 'dashboard/constants/permissions.js';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/canned-response'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          redirect: to => {
            return { name: 'canned_list', params: to.params };
          },
        },
        {
          path: 'list',
          name: 'canned_list',
          meta: {
            featureFlag: FEATURE_FLAGS.CANNED_RESPONSES,
            permissions: CONVERSATION_ACCESS_PERMISSIONS,
          },
          redirect: to => {
            return {
              name: 'outbound_templates_index',
              params: to.params,
            };
          },
        },
      ],
    },
  ],
};
