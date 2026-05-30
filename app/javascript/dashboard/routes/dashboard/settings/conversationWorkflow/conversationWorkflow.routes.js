import { frontendURL } from '../../../../helper/URLHelper';
import { conversationSettingsTabs } from '../conversationSettingsTabs';

const SettingsTabsWrapper = () =>
  import('../components/SettingsTabsWrapper.vue');
const ConversationWorkflowIndex = () => import('./index.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/conversation-workflow'),
      component: SettingsTabsWrapper,
      props: {
        tabs: conversationSettingsTabs,
      },
      children: [
        {
          path: '',
          name: 'conversation_workflow_index',
          component: ConversationWorkflowIndex,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
