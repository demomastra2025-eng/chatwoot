import { frontendURL } from '../../../../helper/URLHelper';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { workspaceSettingsTabs } from '../workspaceSettingsTabs';
const Index = () => import('./Index.vue');
const Scheduling = () => import('./Scheduling.vue');
const LeadForms = () => import('../leadForms/Index.vue');
const SettingsTabsWrapper = () =>
  import('../components/SettingsTabsWrapper.vue');
const AttributesHome = () => import('../attributes/Index.vue');

const schedulingSettingsTabs = [
  {
    labelKey: 'SIDEBAR.SCHEDULING',
    routeName: 'scheduling_settings_index',
    activeOn: ['scheduling_settings_index'],
  },
  {
    labelKey: 'ATTRIBUTES_MGMT.HEADER',
    routeName: 'scheduling_fields_settings_index',
    activeOn: ['scheduling_fields_settings_index'],
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
          component: AttributesHome,
          props: {
            initialTab: 'appointment',
            showEntityTabs: false,
            tabs: ['appointment'],
          },
          meta: {
            permissions: ['administrator'],
            featureFlag: FEATURE_FLAGS.SCHEDULING,
          },
        },
      ],
    },
  ],
};
