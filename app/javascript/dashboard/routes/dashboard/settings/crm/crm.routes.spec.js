import crmRoutes, { TaskCatalogSettingsPage } from './crm.routes';

describe('CRM settings routes', () => {
  const parentByPath = suffix =>
    crmRoutes.routes.find(route => route.path.endsWith(suffix));
  const childByName = (parent, name) =>
    parent.children.find(route => route.name === name);

  it('keeps deal pipelines and task settings local but redirects their fields', () => {
    const dealParent = parentByPath('/settings/crm');
    const taskParent = parentByPath('/settings/crm/tasks');

    expect(dealParent.props.tabs).toEqual([
      expect.objectContaining({ routeName: 'crm_settings_index' }),
    ]);
    expect(taskParent.props.tabs).toEqual([
      expect.objectContaining({ routeName: 'crm_task_settings_index' }),
    ]);
    expect(dealParent.props.keepAlive).toBe(false);
    expect(taskParent.props.keepAlive).toBe(false);
    const taskSettingsRoute = childByName(
      taskParent,
      'crm_task_settings_index'
    );
    expect(taskSettingsRoute.component).toBe(TaskCatalogSettingsPage);

    expect(
      childByName(dealParent, 'crm_deal_fields_settings_index').redirect({
        params: { accountId: '7' },
        query: {},
      })
    ).toEqual({
      name: 'workspace_additional_fields_settings_index',
      params: { accountId: '7' },
      query: { tab: 'deal' },
    });
    expect(
      childByName(taskParent, 'crm_task_fields_settings_index').redirect({
        params: { accountId: '7' },
        query: {},
      })
    ).toEqual({
      name: 'workspace_additional_fields_settings_index',
      params: { accountId: '7' },
      query: { tab: 'task' },
    });
  });
});
