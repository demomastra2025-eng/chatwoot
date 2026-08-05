import accountRoutes from './account.routes';
import {
  WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES,
  workspaceSettingsTabs,
} from '../workspaceSettingsTabs';

describe('account settings routes', () => {
  it('places lead forms inside general settings', () => {
    const generalSettingsRoute = accountRoutes.routes.find(route =>
      route.path.endsWith('/settings/general')
    );
    const leadFormsRoute = generalSettingsRoute.children.find(
      route => route.name === 'lead_forms_index'
    );

    expect(leadFormsRoute).toMatchObject({
      path: 'lead-forms',
      meta: { permissions: ['administrator'] },
    });
    expect(generalSettingsRoute.props.tabs).toBe(workspaceSettingsTabs);
    expect(workspaceSettingsTabs).toContainEqual({
      labelKey: 'SIDEBAR.LEAD_FORMS',
      routeName: 'lead_forms_index',
      activeOn: ['lead_forms_index'],
    });
    expect(WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES).not.toContain(
      'lead_forms_index'
    );
  });

  it('redirects the legacy settings URL to general settings lead forms', () => {
    const legacyRoute = accountRoutes.routes.find(route =>
      route.path.endsWith('/settings/lead-forms')
    );

    expect(legacyRoute.redirect({ params: { accountId: '43' } })).toEqual({
      name: 'lead_forms_index',
      params: { accountId: '43' },
    });
  });
});
