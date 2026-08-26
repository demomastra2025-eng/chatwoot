import conversationWorkflowRoutes from './conversationWorkflow.routes';

describe('conversation workflow settings routes', () => {
  const routeByName = name =>
    conversationWorkflowRoutes.routes.find(route => route.name === name);

  it('redirects all legacy conversation settings into workspace settings', () => {
    const route = { params: { accountId: '43' }, query: { source: 'legacy' } };

    expect(routeByName('conversation_workflow_index').redirect(route)).toEqual({
      name: 'workspace_conversation_workflow_settings_index',
      params: { accountId: '43' },
      query: { source: 'legacy' },
    });
    expect(
      routeByName('conversation_fields_settings_index').redirect(route)
    ).toEqual({
      name: 'workspace_additional_fields_settings_index',
      params: { accountId: '43' },
      query: { source: 'legacy', tab: 'conversation_attribute' },
    });
    expect(
      routeByName('conversation_visibility_settings_index').redirect(route)
    ).toEqual({
      name: 'workspace_sidebar_visibility_settings_index',
      params: { accountId: '43' },
      query: { source: 'legacy' },
    });
  });
});
