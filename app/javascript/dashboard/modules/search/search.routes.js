import { frontendURL } from '../../helper/URLHelper';
import {
  CONVERSATION_ACCESS_PERMISSIONS,
  CONTACT_ACCESS_PERMISSIONS,
  PORTAL_PERMISSIONS,
} from 'dashboard/constants/permissions.js';

import SearchView from './components/SearchView.vue';

export const routes = [
  {
    path: frontendURL('accounts/:accountId/search/:tab?'),
    name: 'search',
    meta: {
      permissions: [
        ...CONVERSATION_ACCESS_PERMISSIONS,
        ...CONTACT_ACCESS_PERMISSIONS,
        PORTAL_PERMISSIONS,
      ],
    },
    component: SearchView,
  },
];
