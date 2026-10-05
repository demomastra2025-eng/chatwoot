import { FEATURE_FLAGS } from '../../../../featureFlags';
import store from '../../../../store';
import crmRoutes, { TaskSettingsPage } from './crm.routes';

vi.mock('../../../../store', () => ({
  default: {
    getters: { 'accounts/isFeatureEnabledonAccount': vi.fn() },
  },
}));

describe('CRM settings routes', () => {
  const parentByPath = suffix =>
    crmRoutes.routes.find(route => route.path.endsWith(suffix));
  const childByName = (parent, name) =>
    parent.children.find(route => route.name === name);

  const enableFeatures = (...flags) =>
    store.getters['accounts/isFeatureEnabledonAccount'].mockImplementation(
      (_accountId, flag) => flags.includes(flag)
    );
  const enterRoute = (route, to) => {
    const next = vi.fn();
    route.beforeEnter(
      { params: { accountId: '7' }, query: {}, ...to },
      {},
      next
    );
    return next;
  };

  beforeEach(() => {
    store.getters['accounts/isFeatureEnabledonAccount'].mockReset();
  });

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

  it('mounts the task statuses page inside the tabs wrapper with CRM settings permissions', () => {
    const taskParent = parentByPath('/settings/crm/tasks');
    const taskSettingsRoute = childByName(
      taskParent,
      'crm_task_settings_index'
    );

    expect(taskSettingsRoute.component).toBe(TaskSettingsPage);
    expect(taskSettingsRoute.meta.permissions).toEqual([
      'administrator',
      'crm_settings_view',
      'crm_settings_manage',
    ]);
    expect(taskParent.component).toBe(parentByPath('/settings/crm').component);
  });

  it('lets the pipeline editor use the full width without a second back button', () => {
    const dealParent = parentByPath('/settings/crm');

    expect(dealParent.props.fullWidth).toBe(true);
    expect(dealParent.props.showBackButton).toBe(false);
  });

  it('sends the create-task-status link to the task settings page', () => {
    const dealRoute = childByName(
      parentByPath('/settings/crm'),
      'crm_settings_index'
    );
    enableFeatures(FEATURE_FLAGS.CRM_DEALS, FEATURE_FLAGS.CRM_TASKS);

    const next = enterRoute(dealRoute, {
      query: { action: 'create-task-status' },
    });

    expect(next).toHaveBeenCalledWith({
      name: 'crm_task_settings_index',
      params: { accountId: '7' },
      query: { action: 'create-task-status' },
    });
  });

  it('keeps the pipelines page for plain visits when deals are enabled', () => {
    const dealRoute = childByName(
      parentByPath('/settings/crm'),
      'crm_settings_index'
    );
    enableFeatures(FEATURE_FLAGS.CRM_DEALS, FEATURE_FLAGS.CRM_TASKS);

    expect(enterRoute(dealRoute, {})).toHaveBeenCalledWith();
  });

  it('redirects the pipelines page to task settings when only tasks are enabled', () => {
    const dealRoute = childByName(
      parentByPath('/settings/crm'),
      'crm_settings_index'
    );
    enableFeatures(FEATURE_FLAGS.CRM_TASKS);

    expect(enterRoute(dealRoute, {})).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'crm_task_settings_index' })
    );
  });
});
