import { FEATURE_FLAGS } from '../../../../featureFlags';
const Bot = () => import('./Index.vue');
import { frontendURL } from '../../../../helper/URLHelper';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/agent-bots'),
      meta: {
        permissions: ['administrator'],
      },
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'agent_bots',
          component: Bot,
          meta: {
            featureFlag: FEATURE_FLAGS.AGENT_BOTS,
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
