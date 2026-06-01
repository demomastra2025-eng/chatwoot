import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import { conversationSettingsTabs } from '../conversationSettingsTabs';

const SettingsTabsWrapper = () =>
  import('../components/SettingsTabsWrapper.vue');
const ConversationWorkflowIndex = () => import('./index.vue');
const AttributesHome = () => import('../attributes/Index.vue');
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
        {
          path: 'fields',
          name: 'conversation_fields_settings_index',
          component: AttributesHome,
          props: {
            initialTab: 'conversation_attribute',
            showEntityTabs: false,
            tabs: ['conversation_attribute'],
          },
          meta: {
            permissions: ['administrator'],
            featureFlag: FEATURE_FLAGS.CUSTOM_ATTRIBUTES,
          },
        },
      ],
    },
  ],
};
