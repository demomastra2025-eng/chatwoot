import { frontendURL } from '../../../../helper/URLHelper';

const conversationSettingsRedirect = to => ({
  name: 'workspace_conversation_settings_index',
  params: { accountId: to.params.accountId },
  query: to.query,
  hash: to.hash,
});

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/captain/settings'),
      name: 'captain_settings_index',
      redirect: conversationSettingsRedirect,
    },
    {
      path: frontendURL('accounts/:accountId/settings/captain'),
      redirect: conversationSettingsRedirect,
    },
  ],
};
