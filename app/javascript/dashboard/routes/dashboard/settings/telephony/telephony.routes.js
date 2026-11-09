import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';

const SettingsWrapper = () => import('../SettingsWrapper.vue');
const TelephonySettings = () => import('./Index.vue');

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/telephony'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'settings_telephony_index',
          component: TelephonySettings,
          meta: {
            featureFlag: FEATURE_FLAGS.INBOX_MANAGEMENT,
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
