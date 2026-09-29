import accountRoutes, {
  WORKSPACE_ADDITIONAL_FIELD_TABS,
  additionalFieldsProps,
} from './account.routes';
import {
  WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES,
  workspaceSettingsTabs,
} from '../workspaceSettingsTabs';
import { SLA_SETTINGS_ROUTE_META } from '../sla/slaSettingsPolicy';

const generalSettingsRoute = () =>
  accountRoutes.routes.find(route => route.path.endsWith('/settings/general'));
const generalChild = name =>
  generalSettingsRoute().children.find(route => route.name === name);

describe('account settings routes', () => {
  it('keeps the settings hub under /settings/general without top tabs', () => {
    expect(generalSettingsRoute().props).toEqual({
      tabs: workspaceSettingsTabs,
      showTabs: false,
    });
    expect(
      generalSettingsRoute().children.map(route => [route.path, route.name])
    ).toEqual([
      ['', 'general_settings_index'],
      ['navigation', 'workspace_sidebar_visibility_settings_index'],
      ['conversations', 'workspace_conversation_settings_index'],
      [
        'conversation-navigation',
        'workspace_conversation_visibility_settings_index',
      ],
      [
        'conversation-closure',
        'workspace_conversation_workflow_settings_index',
      ],
      ['sla', 'workspace_sla_settings_index'],
      ['additional-fields', 'workspace_additional_fields_settings_index'],
      ['lead-forms', 'lead_forms_index'],
    ]);
  });

  it('limits company and conversation settings to administrators', () => {
    [
      'general_settings_index',
      'workspace_sidebar_visibility_settings_index',
      'workspace_conversation_settings_index',
      'workspace_conversation_visibility_settings_index',
      'workspace_conversation_workflow_settings_index',
      'lead_forms_index',
    ].forEach(name => {
      expect(generalChild(name).meta).toEqual({
        permissions: ['administrator'],
      });
    });
  });

  it('keeps lead forms routable without a general-settings tab', () => {
    expect(workspaceSettingsTabs).not.toContainEqual(
      expect.objectContaining({ routeName: 'lead_forms_index' })
    );
    expect(WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES).not.toContain(
      'lead_forms_index'
    );
  });

  it('uses the SLA policy meta so the paywall stays reachable', () => {
    const slaRoute = generalChild('workspace_sla_settings_index');

    expect(slaRoute.meta).toBe(SLA_SETTINGS_ROUTE_META);
    expect(slaRoute.meta.featureFlag).toBeUndefined();
  });

  it('opens additional fields with the requested entity tab', () => {
    const additionalFieldsRoute = generalChild(
      'workspace_additional_fields_settings_index'
    );

    expect(additionalFieldsRoute.meta).toEqual({
      permissions: [
        'administrator',
        'crm_settings_view',
        'crm_settings_manage',
      ],
    });
    expect(additionalFieldsRoute.props).toBe(additionalFieldsProps);
    expect(additionalFieldsProps({ query: { tab: 'task' } })).toEqual({
      initialTab: 'task',
      tabs: WORKSPACE_ADDITIONAL_FIELD_TABS,
    });
    expect(additionalFieldsProps({ query: { tab: ['deal', 'task'] } })).toEqual(
      {
        initialTab: 'deal',
        tabs: WORKSPACE_ADDITIONAL_FIELD_TABS,
      }
    );
    expect(
      additionalFieldsProps({ query: { tab: 'unknown' } }).initialTab
    ).toBe('conversation_attribute');
    expect(WORKSPACE_ADDITIONAL_FIELD_TABS).toEqual([
      'conversation_attribute',
      'contact_attribute',
      'company_attribute',
      'deal',
      'task',
      'appointment',
    ]);
  });

  it('redirects the legacy lead forms URL', () => {
    const legacyRoute = accountRoutes.routes.find(route =>
      route.path.endsWith('/settings/lead-forms')
    );

    expect(legacyRoute.redirect({ params: { accountId: '43' } })).toEqual({
      name: 'lead_forms_index',
      params: { accountId: '43' },
    });
  });

  it('redirects scheduling fields to the appointment tab of additional fields', () => {
    const schedulingRoute = accountRoutes.routes.find(route =>
      route.path.endsWith('/settings/scheduling')
    );
    const fieldsRoute = schedulingRoute.children.find(
      route => route.name === 'scheduling_fields_settings_index'
    );

    expect(schedulingRoute.props.showTabs).toBe(false);
    expect(fieldsRoute.redirect({ params: { accountId: '5' } })).toEqual({
      name: 'workspace_additional_fields_settings_index',
      params: { accountId: '5' },
      query: { tab: 'appointment' },
    });
  });
});
