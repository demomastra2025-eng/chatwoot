import { frontendURL } from 'dashboard/helper/URLHelper';
const InboxListView = () => import('./InboxList.vue');
const InboxDetailView = () => import('./InboxView.vue');
const InboxEmptyStateView = () => import('./InboxEmptyState.vue');
import { CONVERSATION_ACCESS_PERMISSIONS } from 'dashboard/constants/permissions.js';

export const routes = [
  {
    path: frontendURL('accounts/:accountId/inbox-view'),
    component: InboxListView,
    children: [
      {
        path: '',
        name: 'inbox_view',
        component: InboxEmptyStateView,
        meta: {
          permissions: CONVERSATION_ACCESS_PERMISSIONS,
        },
      },
      {
        path: ':type/:id',
        name: 'inbox_view_conversation',
        component: InboxDetailView,
        meta: {
          permissions: CONVERSATION_ACCESS_PERMISSIONS,
        },
      },
    ],
  },
];
