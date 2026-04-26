/* eslint arrow-body-style: 0 */
import { frontendURL } from '../../../helper/URLHelper';
const SettingsWrapper = () => import('../settings/SettingsWrapper.vue');
const NotificationsView = () => import('./components/NotificationsView.vue');
export const routes = [
  {
    path: frontendURL('accounts/:accountId/notifications'),
    component: SettingsWrapper,
    children: [
      {
        path: '',
        name: 'notifications_index',
        component: NotificationsView,
        meta: {
          permissions: ['administrator', 'agent', 'custom_role'],
        },
      },
    ],
  },
];
