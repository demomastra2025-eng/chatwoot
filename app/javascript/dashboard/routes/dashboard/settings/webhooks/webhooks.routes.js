import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';

const SettingsWrapper = () => import('../SettingsWrapper.vue');
const Webhook = () => import('../integrations/Webhooks/Index.vue');

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/webhooks'),
      meta: {
        permissions: ['administrator'],
      },
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'settings_webhooks',
          component: Webhook,
          meta: {
            featureFlag: FEATURE_FLAGS.INTEGRATIONS,
            permissions: ['administrator'],
          },
        },
      ],
    },
    // The «Вебхуки» page used to live under the removed AI bots section;
    // bookmarks of the old path land on the page.
    {
      path: frontendURL('accounts/:accountId/settings/agent-bots'),
      redirect: to => ({
        name: 'settings_webhooks',
        params: to.params,
        query: to.query,
        hash: to.hash,
      }),
    },
  ],
};
