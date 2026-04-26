import { FEATURE_FLAGS } from '../../../../featureFlags';
const Bot = () => import('./Index.vue');
const BotBuilder = () => import('./BotBuilder.vue');
import { frontendURL } from '../../../../helper/URLHelper';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
const SettingsContent = () => import('../Wrapper.vue');
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
    {
      path: frontendURL('accounts/:accountId/settings/agent-bots'),
      meta: {
        permissions: ['administrator'],
      },
      component: SettingsContent,
      props: {
        fullWidth: true,
      },
      children: [
        {
          path: ':botId/builder',
          name: 'agent_bot_builder',
          component: BotBuilder,
          meta: {
            featureFlag: FEATURE_FLAGS.AGENT_BOTS,
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
