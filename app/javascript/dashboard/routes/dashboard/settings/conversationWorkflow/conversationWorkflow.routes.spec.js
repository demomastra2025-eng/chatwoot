import conversationWorkflowRoutes from './conversationWorkflow.routes';

describe('conversation workflow settings routes', () => {
  const routeByName = name =>
    conversationWorkflowRoutes.routes.find(route => route.name === name);
  const route = { params: { accountId: '43' }, query: { source: 'legacy' } };

  it('redirects the legacy closure URL to Conversations > Conversation closure', () => {
    expect(routeByName('conversation_workflow_index').redirect(route)).toEqual({
      name: 'workspace_conversation_workflow_settings_index',
      params: { accountId: '43' },
      query: { source: 'legacy' },
    });
  });

  it('redirects the legacy fields URL to the conversation tab of additional fields', () => {
    expect(
      routeByName('conversation_fields_settings_index').redirect(route)
    ).toEqual({
      name: 'workspace_additional_fields_settings_index',
      params: { accountId: '43' },
      query: { source: 'legacy', tab: 'conversation_attribute' },
    });
  });

  it('redirects the legacy visibility URL to Conversation navigation, not company navigation', () => {
    expect(
      routeByName('conversation_visibility_settings_index').redirect(route)
    ).toEqual({
      name: 'workspace_conversation_visibility_settings_index',
      params: { accountId: '43' },
      query: { source: 'legacy' },
    });
  });

  it('keeps only redirect routes', () => {
    conversationWorkflowRoutes.routes.forEach(legacyRoute => {
      expect(legacyRoute.component).toBeUndefined();
      expect(typeof legacyRoute.redirect).toBe('function');
    });
  });
});
