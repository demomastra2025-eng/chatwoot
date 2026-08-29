import { frontendURL } from '../../../../helper/URLHelper';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { workspaceSettingsTabs } from '../workspaceSettingsTabs';
import { SLA_SETTINGS_ROUTE_META } from '../sla/slaSettingsPolicy';
const Index = () => import('./Index.vue');
const SidebarVisibilitySettings = () =>
  import('./SidebarVisibilitySettings.vue');
const ConversationSettings = () => import('./ConversationSettings.vue');
const Scheduling = () => import('./Scheduling.vue');
const LeadForms = () => import('../leadForms/Index.vue');
const SettingsTabsWrapper = () =>
  import('../components/SettingsTabsWrapper.vue');
const AttributesHome = () => import('../attributes/Index.vue');
const ConversationWorkflow = () => import('../conversationWorkflow/index.vue');
const SLASettings = () => import('../sla/Index.vue');

export const WORKSPACE_ADDITIONAL_FIELD_TABS = [
  'conversation_attribute',
  'contact_attribute',
  'company_attribute',
  'deal',
  'task',
  'appointment',
];

const additionalFieldsProps = route => {
  const requestedTab = Array.isArray(route.query.tab)
    ? route.query.tab[0]
    : route.query.tab;

  return {
    initialTab: WORKSPACE_ADDITIONAL_FIELD_TABS.includes(requestedTab)
      ? requestedTab
      : WORKSPACE_ADDITIONAL_FIELD_TABS[0],
    tabs: WORKSPACE_ADDITIONAL_FIELD_TABS,
  };
};

const schedulingSettingsTabs = [
  {
    labelKey: 'SIDEBAR.SCHEDULING',
    routeName: 'scheduling_settings_index',
    activeOn: ['scheduling_settings_index'],
  },
];

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/general'),
      meta: {
        permissions: ['administrator'],
      },
      component: SettingsTabsWrapper,
      props: {
        tabs: workspaceSettingsTabs,
        showTabs: false,
      },
      children: [
        {
          path: '',
          name: 'general_settings_index',
          component: Index,
          meta: {
            permissions: ['administrator'],
          },
        },
        {
          path: 'visibility',
          name: 'workspace_sidebar_visibility_settings_index',
          component: SidebarVisibilitySettings,
          meta: {
            permissions: ['administrator'],
          },
        },
        {
          path: 'conversations',
          name: 'workspace_conversation_settings_index',
          component: ConversationSettings,
          meta: {
            permissions: ['administrator'],
          },
        },
        {
          path: 'conversation-closure',
          name: 'workspace_conversation_workflow_settings_index',
          component: ConversationWorkflow,
          meta: {
            permissions: ['administrator'],
          },
        },
        {
          path: 'sla',
          name: 'workspace_sla_settings_index',
          component: SLASettings,
          meta: SLA_SETTINGS_ROUTE_META,
        },
        {
          path: 'additional-fields',
          name: 'workspace_additional_fields_settings_index',
          component: AttributesHome,
          props: additionalFieldsProps,
          meta: {
            permissions: [
              'administrator',
              'crm_settings_view',
              'crm_settings_manage',
            ],
          },
        },
        {
          path: 'lead-forms',
          name: 'lead_forms_index',
          component: LeadForms,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
    {
      path: frontendURL('accounts/:accountId/settings/lead-forms'),
      redirect: to => ({ name: 'lead_forms_index', params: to.params }),
    },
    {
      path: frontendURL('accounts/:accountId/settings/scheduling'),
      meta: {
        permissions: ['administrator'],
        featureFlag: FEATURE_FLAGS.SCHEDULING,
      },
      component: SettingsTabsWrapper,
      props: {
        tabs: schedulingSettingsTabs,
        showTabs: false,
      },
      children: [
        {
          path: '',
          name: 'scheduling_settings_index',
          component: Scheduling,
          meta: {
            permissions: ['administrator'],
            featureFlag: FEATURE_FLAGS.SCHEDULING,
          },
        },
        {
          path: 'fields',
          name: 'scheduling_fields_settings_index',
          redirect: to => ({
            name: 'workspace_additional_fields_settings_index',
            params: to.params,
            query: { tab: 'appointment' },
          }),
        },
      ],
    },
  ],
};
