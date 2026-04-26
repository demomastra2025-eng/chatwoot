import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
const IntegrationHooks = () => import('./IntegrationHooks.vue');
const Index = () => import('./Index.vue');
const Webhook = () => import('./Webhooks/Index.vue');
const DashboardApps = () => import('./DashboardApps/Index.vue');
const Slack = () => import('./Slack.vue');
const Linear = () => import('./Linear.vue');
const Notion = () => import('./Notion.vue');
const Shopify = () => import('./Shopify.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/integrations'),
      component: SettingsWrapper,
      props: {},
      children: [
        {
          path: '',
          name: 'settings_applications',
          component: Index,
          meta: {
            featureFlag: FEATURE_FLAGS.INTEGRATIONS,
            permissions: ['administrator'],
          },
        },
        {
          path: 'dashboard_apps',
          component: DashboardApps,
          name: 'settings_integrations_dashboard_apps',
          meta: {
            featureFlag: FEATURE_FLAGS.INTEGRATIONS,
            permissions: ['administrator'],
          },
        },
        {
          path: 'webhook',
          component: Webhook,
          name: 'settings_integrations_webhook',
          meta: {
            featureFlag: FEATURE_FLAGS.INTEGRATIONS,
            permissions: ['administrator'],
          },
        },
      ],
    },
    {
      path: frontendURL('accounts/:accountId/settings/integrations'),
      component: SettingsWrapper,
      children: [
        {
          path: 'slack',
          name: 'settings_integrations_slack',
          component: Slack,
          meta: {
            featureFlag: FEATURE_FLAGS.INTEGRATIONS,
            permissions: ['administrator'],
          },
          props: route => ({ code: route.query.code }),
        },
        {
          path: 'linear',
          name: 'settings_integrations_linear',
          component: Linear,
          meta: {
            permissions: ['administrator'],
          },
          props: route => ({ code: route.query.code }),
        },
        {
          path: 'notion',
          name: 'settings_integrations_notion',
          component: Notion,
          meta: {
            permissions: ['administrator'],
          },
          props: route => ({ code: route.query.code }),
        },
        {
          path: 'shopify',
          name: 'settings_integrations_shopify',
          component: Shopify,
          meta: {
            featureFlag: FEATURE_FLAGS.INTEGRATIONS,
            permissions: ['administrator'],
          },
          props: route => ({ error: route.query.error }),
        },
        {
          path: ':integration_id',
          name: 'settings_applications_integration',
          component: IntegrationHooks,
          meta: {
            featureFlag: FEATURE_FLAGS.INTEGRATIONS,
            permissions: ['administrator'],
          },
          props: route => ({
            integrationId: route.params.integration_id,
          }),
        },
      ],
    },
  ],
};
