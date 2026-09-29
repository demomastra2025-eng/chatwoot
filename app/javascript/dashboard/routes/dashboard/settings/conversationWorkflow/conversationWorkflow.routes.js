import { frontendURL } from '../../../../helper/URLHelper';

// The conversation settings moved into the settings hub under
// /settings/general/*. The old URLs stay as redirects for bookmarks and
// links in help texts.
const redirectToWorkspaceSettings = (to, name, tab) => ({
  name,
  params: to.params,
  query: {
    ...to.query,
    ...(tab ? { tab } : {}),
  },
});

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/conversation-workflow'),
      name: 'conversation_workflow_index',
      redirect: to =>
        redirectToWorkspaceSettings(
          to,
          'workspace_conversation_workflow_settings_index'
        ),
    },
    {
      path: frontendURL(
        'accounts/:accountId/settings/conversation-workflow/fields'
      ),
      name: 'conversation_fields_settings_index',
      redirect: to =>
        redirectToWorkspaceSettings(
          to,
          'workspace_additional_fields_settings_index',
          'conversation_attribute'
        ),
    },
    {
      path: frontendURL(
        'accounts/:accountId/settings/conversation-workflow/visibility'
      ),
      name: 'conversation_visibility_settings_index',
      redirect: to =>
        redirectToWorkspaceSettings(
          to,
          'workspace_conversation_visibility_settings_index'
        ),
    },
  ],
};
