import accountRoutes, {
  WORKSPACE_ADDITIONAL_FIELD_TABS,
} from './account.routes';
import {
  WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES,
  workspaceSettingsTabs,
} from '../workspaceSettingsTabs';
import { SLA_SETTINGS_ROUTE_META } from '../sla/slaSettingsPolicy';

describe('account settings routes', () => {
  it('exposes account-wide sidebar visibility for administrators', () => {
    const generalSettingsRoute = accountRoutes.routes.find(route =>
      route.path.endsWith('/settings/general')
    );
    const visibilityRoute = generalSettingsRoute.children.find(
      route => route.name === 'workspace_sidebar_visibility_settings_index'
    );

    expect(visibilityRoute).toMatchObject({
      path: 'visibility',
      meta: { permissions: ['administrator'] },
    });
  });

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

  it('centralizes conversation workflow, SLA, and six additional-field entities', () => {
    const generalSettingsRoute = accountRoutes.routes.find(route =>
      route.path.endsWith('/settings/general')
    );
    const routeByName = name =>
      generalSettingsRoute.children.find(route => route.name === name);

    expect(
      routeByName('workspace_conversation_workflow_settings_index')
    ).toMatchObject({
      path: 'conversation-closure',
      meta: { permissions: ['administrator'] },
    });
    const slaRoute = routeByName('workspace_sla_settings_index');
    expect(slaRoute.path).toBe('sla');
    expect(slaRoute.meta).toBe(SLA_SETTINGS_ROUTE_META);
    expect(slaRoute.meta.featureFlag).toBeUndefined();

    const additionalFieldsRoute = routeByName(
      'workspace_additional_fields_settings_index'
    );
    expect(additionalFieldsRoute).toMatchObject({
      path: 'additional-fields',
      meta: {
        permissions: [
          'administrator',
          'crm_settings_view',
          'crm_settings_manage',
        ],
      },
    });
    expect(additionalFieldsRoute.props({ query: { tab: 'task' } })).toEqual({
      initialTab: 'task',
      tabs: WORKSPACE_ADDITIONAL_FIELD_TABS,
    });
    expect(WORKSPACE_ADDITIONAL_FIELD_TABS).toEqual([
      'conversation_attribute',
      'contact_attribute',
      'company_attribute',
      'deal',
      'task',
      'appointment',
    ]);
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
