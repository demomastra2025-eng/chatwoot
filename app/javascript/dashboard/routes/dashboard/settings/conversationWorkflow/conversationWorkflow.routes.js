import { frontendURL } from '../../../../helper/URLHelper';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
const ConversationWorkflowIndex = () => import('./index.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/conversation-workflow'),
      component: SettingsWrapper,
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
