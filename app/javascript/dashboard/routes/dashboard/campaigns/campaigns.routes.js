import { frontendURL } from 'dashboard/helper/URLHelper.js';
import { CONVERSATION_ACCESS_PERMISSIONS } from 'dashboard/constants/permissions.js';

const OutboundPageRouteView = () => import('./pages/OutboundPageRouteView.vue');
const OutboundCampaignsPage = () => import('./pages/OutboundCampaignsPage.vue');
const OutboundTouchPlansPage = () =>
  import('./pages/OutboundTouchPlansPage.vue');
const OutboundTemplatesPage = () => import('./pages/OutboundTemplatesPage.vue');
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

const campaignsMeta = {
  featureFlag: FEATURE_FLAGS.CAMPAIGNS,
  permissions: ['administrator'],
};

const outboundWorkspaceMeta = {
  featureFlag: FEATURE_FLAGS.CAMPAIGNS,
  permissions: CONVERSATION_ACCESS_PERMISSIONS,
};

const touchesMeta = outboundWorkspaceMeta;

const templatesMeta = touchesMeta;

const campaignsRoutes = {
  routes: [
    {
      path: frontendURL('accounts/:accountId/outbound'),
      component: OutboundPageRouteView,
      children: [
        {
          path: '',
          name: 'outbound_index',
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'broadcasts',
          name: 'outbound_broadcasts_index',
          meta: outboundWorkspaceMeta,
          component: OutboundCampaignsPage,
          props: {
            mode: 'mass',
          },
        },
        // Legacy personal-broadcast URL kept as a redirect so existing bookmarks
        // and saved Captain/UI actions land on the canonical touches route.
        {
          path: 'broadcasts/personal',
          name: 'outbound_broadcasts_personal_index',
          meta: touchesMeta,
          redirect: to => {
            return {
              name: 'outbound_touches_index',
              params: to.params,
              query: to.query,
            };
          },
        },
        {
          path: 'broadcasts/outbound',
          name: 'outbound_broadcasts_outbound_index',
          meta: campaignsMeta,
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'broadcasts/live_chat',
          name: 'outbound_broadcasts_livechat_index',
          meta: campaignsMeta,
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'audiences',
          name: 'outbound_audiences_index',
          meta: campaignsMeta,
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'touches',
          name: 'outbound_touches_index',
          meta: touchesMeta,
          component: OutboundCampaignsPage,
          props: {
            mode: 'touches',
          },
        },
        {
          path: 'touch-plans',
          name: 'outbound_touch_plans_index',
          meta: touchesMeta,
          component: OutboundTouchPlansPage,
        },
        {
          path: 'templates',
          name: 'outbound_templates_index',
          meta: templatesMeta,
          component: OutboundTemplatesPage,
        },
      ],
    },
    {
      path: frontendURL('accounts/:accountId/campaigns'),
      component: OutboundPageRouteView,
      children: [
        {
          path: '',
          redirect: to => {
            return { name: 'outbound_broadcasts_index', params: to.params };
          },
        },
        {
          path: 'ongoing',
          name: 'campaigns_ongoing_index',
          meta: campaignsMeta,
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'one_off',
          name: 'campaigns_one_off_index',
          meta: campaignsMeta,
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'live_chat',
          name: 'campaigns_livechat_index',
          meta: campaignsMeta,
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'outbound',
          name: 'campaigns_outbound_index',
          meta: campaignsMeta,
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'sms',
          name: 'campaigns_sms_index',
          meta: campaignsMeta,
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
        {
          path: 'whatsapp',
          name: 'campaigns_whatsapp_index',
          meta: {
            ...campaignsMeta,
            featureFlag: FEATURE_FLAGS.WHATSAPP_CAMPAIGNS,
          },
          redirect: to => {
            return {
              name: 'outbound_broadcasts_index',
              params: to.params,
            };
          },
        },
      ],
    },
  ],
};

export default campaignsRoutes;
