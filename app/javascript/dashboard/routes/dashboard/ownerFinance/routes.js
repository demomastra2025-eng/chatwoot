import { frontendURL } from 'dashboard/helper/URLHelper';

const OwnerFinancePage = () => import('./pages/OwnerFinancePage.vue');

export const routes = [
  {
    path: frontendURL('accounts/:accountId/owner-finance'),
    name: 'owner_finance_index',
    component: OwnerFinancePage,
    meta: {
      permissions: ['administrator', 'agent', 'custom_role'],
      ownerFinanceOnly: true,
    },
  },
];
