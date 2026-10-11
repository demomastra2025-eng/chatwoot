import { frontendURL } from '../../../../helper/URLHelper';

const conversationSettingsRedirect = to => ({
  name: 'workspace_conversation_settings_index',
  params: { accountId: to.params.accountId },
  query: to.query,
  hash: to.hash,
});

// captain/settings is now the AI settings page of the «ИИ-агенты» section
// (captain_ai_settings_index), so only the old settings URL redirects here.
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/captain'),
      redirect: conversationSettingsRedirect,
    },
  ],
};
