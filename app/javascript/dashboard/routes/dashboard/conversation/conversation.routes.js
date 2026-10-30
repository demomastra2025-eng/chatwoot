/* eslint arrow-body-style: 0 */
import { frontendURL } from '../../../helper/URLHelper';
const ConversationView = () => import('./ConversationView.vue');
import inboxDialogRoutes from '../settings/inbox/inboxDialog.routes';
import { CONVERSATION_ACCESS_PERMISSIONS } from '../../../constants/permissions';
import { FEATURE_FLAGS } from '../../../featureFlags';
import store from '../../../store';
import { redirectToCommunicationThread } from './redirectToCommunicationThread';

const isCommunicationThreadsEnabled = accountId => {
  const checkFeature = store.getters?.['accounts/isFeatureEnabledonAccount'];
  return Boolean(
    checkFeature?.(accountId, FEATURE_FLAGS.COMMUNICATION_THREADS)
  );
};

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/dashboard'),
      name: 'home',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: () => {
        return { inboxId: 0 };
      },
    },
    {
      path: frontendURL('accounts/:accountId/communication_threads'),
      name: 'communication_threads_dashboard',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
        featureFlag: FEATURE_FLAGS.COMMUNICATION_THREADS,
      },
      component: ConversationView,
      props: () => {
        return { inboxId: 0, communicationThreadMode: true };
      },
    },
    {
      path: frontendURL(
        'accounts/:accountId/communication_threads/:communication_thread_id'
      ),
      name: 'communication_thread_conversation',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
        featureFlag: FEATURE_FLAGS.COMMUNICATION_THREADS,
      },
      component: ConversationView,
      props: route => {
        return {
          inboxId: 0,
          conversationId: route.params.communication_thread_id,
          communicationThreadMode: true,
        };
      },
    },
    {
      path: frontendURL(
        'accounts/:accountId/communication_threads/contact/:contact_id'
      ),
      name: 'communication_thread_contact',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
        featureFlag: FEATURE_FLAGS.COMMUNICATION_THREADS,
      },
      component: ConversationView,
      props: route => {
        return {
          inboxId: 0,
          personContactId: route.params.contact_id,
          communicationThreadMode: true,
        };
      },
    },
    ...inboxDialogRoutes.routes,
    {
      path: frontendURL('accounts/:accountId/conversations/:conversation_id'),
      name: 'inbox_conversation',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      beforeEnter: redirectToCommunicationThread,
      component: ConversationView,
      props: route => {
        return { inboxId: 0, conversationId: route.params.conversation_id };
      },
    },
    {
      path: frontendURL('accounts/:accountId/inbox/:inbox_id'),
      name: 'inbox_dashboard',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => {
        return { inboxId: route.params.inbox_id };
      },
    },
    {
      path: frontendURL(
        'accounts/:accountId/inbox/:inbox_id/conversations/:conversation_id'
      ),
      name: 'conversation_through_inbox',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => {
        return {
          conversationId: route.params.conversation_id,
          inboxId: route.params.inbox_id,
        };
      },
    },
    {
      path: frontendURL('accounts/:accountId/label/:label'),
      name: 'label_conversations',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => ({
        label: route.params.label,
        communicationThreadMode: isCommunicationThreadsEnabled(
          route.params.accountId
        ),
      }),
    },
    {
      path: frontendURL(
        'accounts/:accountId/label/:label/conversations/:conversation_id'
      ),
      name: 'conversations_through_label',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => ({
        conversationId: route.params.conversation_id,
        label: route.params.label,
        communicationThreadMode: isCommunicationThreadsEnabled(
          route.params.accountId
        ),
      }),
    },
    {
      path: frontendURL('accounts/:accountId/team/:teamId'),
      name: 'team_conversations',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => ({
        teamId: route.params.teamId,
        communicationThreadMode: isCommunicationThreadsEnabled(
          route.params.accountId
        ),
      }),
    },
    {
      path: frontendURL(
        'accounts/:accountId/team/:teamId/conversations/:conversationId'
      ),
      name: 'conversations_through_team',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => ({
        conversationId: route.params.conversationId,
        teamId: route.params.teamId,
        communicationThreadMode: isCommunicationThreadsEnabled(
          route.params.accountId
        ),
      }),
    },
    {
      path: frontendURL('accounts/:accountId/custom_view/:id'),
      name: 'folder_conversations',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => ({
        foldersId: route.params.id,
        communicationThreadMode: isCommunicationThreadsEnabled(
          route.params.accountId
        ),
      }),
    },
    {
      path: frontendURL(
        'accounts/:accountId/custom_view/:id/conversations/:conversation_id'
      ),
      name: 'conversations_through_folders',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => ({
        conversationId: route.params.conversation_id,
        foldersId: route.params.id,
        communicationThreadMode: isCommunicationThreadsEnabled(
          route.params.accountId
        ),
      }),
    },
    {
      path: frontendURL('accounts/:accountId/mentions/conversations'),
      name: 'conversation_mentions',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: () => ({ conversationType: 'mention' }),
    },
    {
      path: frontendURL(
        'accounts/:accountId/mentions/conversations/:conversationId'
      ),
      name: 'conversation_through_mentions',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => ({
        conversationId: route.params.conversationId,
        conversationType: 'mention',
      }),
    },
    {
      path: frontendURL('accounts/:accountId/unattended/conversations'),
      name: 'conversation_unattended',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: () => ({ conversationType: 'unattended' }),
    },
    {
      path: frontendURL(
        'accounts/:accountId/unattended/conversations/:conversationId'
      ),
      name: 'conversation_through_unattended',
      meta: {
        permissions: CONVERSATION_ACCESS_PERMISSIONS,
      },
      component: ConversationView,
      props: route => ({
        conversationId: route.params.conversationId,
        conversationType: 'unattended',
      }),
    },
  ],
};
