import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import ChannelFactory from './ChannelFactory.vue';

import SettingsContent from '../SettingsWrapper.vue';
import Settings from './Settings.vue';
import InboxChannel from './InboxChannels.vue';
import ChannelList from './ChannelList.vue';
import AddAgents from './AddAgents.vue';
import FinishSetup from './FinishSetup.vue';
import { INBOX_FLOW_ROUTE_NAMES } from './helpers/inboxFlowRoutes';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/dialog/inboxes'),
      component: SettingsContent,
      props: params => {
        const isDialogRoot = params.name === INBOX_FLOW_ROUTE_NAMES.dialog.new;

        return {
          headerTitle: 'INBOX_MGMT.HEADER',
          icon: 'mail-inbox-all',
          showBackButton: !isDialogRoot,
          fullWidth: params.name === INBOX_FLOW_ROUTE_NAMES.dialog.show,
        };
      },
      children: [
        {
          path: '',
          redirect: to => {
            return {
              name: INBOX_FLOW_ROUTE_NAMES.dialog.new,
              params: to.params,
            };
          },
        },
        {
          path: 'new',
          component: InboxChannel,
          meta: {
            featureFlag: FEATURE_FLAGS.INBOX_MANAGEMENT,
            permissions: ['administrator'],
            inboxFlow: 'dialogs',
          },
          children: [
            {
              path: '',
              name: INBOX_FLOW_ROUTE_NAMES.dialog.new,
              component: ChannelList,
              meta: {
                featureFlag: FEATURE_FLAGS.INBOX_MANAGEMENT,
                permissions: ['administrator'],
                inboxFlow: 'dialogs',
              },
            },
            {
              path: ':inbox_id/finish',
              name: INBOX_FLOW_ROUTE_NAMES.dialog.finish,
              component: FinishSetup,
              meta: {
                featureFlag: FEATURE_FLAGS.INBOX_MANAGEMENT,
                permissions: ['administrator'],
                inboxFlow: 'dialogs',
              },
            },
            {
              path: ':sub_page',
              name: INBOX_FLOW_ROUTE_NAMES.dialog.page,
              component: ChannelFactory,
              meta: {
                featureFlag: FEATURE_FLAGS.INBOX_MANAGEMENT,
                permissions: ['administrator'],
                inboxFlow: 'dialogs',
              },
              props: route => {
                return { channelName: route.params.sub_page };
              },
            },
            {
              path: ':inbox_id/agents',
              name: INBOX_FLOW_ROUTE_NAMES.dialog.agents,
              meta: {
                featureFlag: FEATURE_FLAGS.INBOX_MANAGEMENT,
                permissions: ['administrator'],
                inboxFlow: 'dialogs',
              },
              component: AddAgents,
            },
          ],
        },
        {
          path: ':inboxId/:tab?',
          name: INBOX_FLOW_ROUTE_NAMES.dialog.show,
          component: Settings,
          meta: {
            featureFlag: FEATURE_FLAGS.INBOX_MANAGEMENT,
            permissions: ['administrator'],
            inboxFlow: 'dialogs',
          },
        },
      ],
    },
  ],
};
