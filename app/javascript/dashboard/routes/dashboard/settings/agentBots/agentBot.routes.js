import { FEATURE_FLAGS } from '../../../../featureFlags';
import Bot from './Index.vue';
import BotBuilder from './BotBuilder.vue';
import { frontendURL } from '../../../../helper/URLHelper';
import SettingsWrapper from '../SettingsWrapper.vue';
import SettingsContent from '../Wrapper.vue';

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
