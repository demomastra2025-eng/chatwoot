import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';
const CompaniesIndex = () => import('./pages/CompaniesIndex.vue');
const CompanyDetailView = () => import('./pages/CompanyDetailView.vue');
import { CONTACT_ACCESS_PERMISSIONS } from '../../../constants/permissions';

const commonMeta = {
  featureFlag: FEATURE_FLAGS.COMPANIES,
  permissions: CONTACT_ACCESS_PERMISSIONS,
};

export const routes = [
  {
    path: frontendURL('accounts/:accountId/companies'),
    component: CompaniesIndex,
    meta: commonMeta,
    children: [
      {
        path: '',
        name: 'companies_dashboard_index',
        component: CompaniesIndex,
        meta: commonMeta,
      },
    ],
  },
  {
    path: frontendURL('accounts/:accountId/companies/:companyId'),
    component: CompanyDetailView,
    meta: commonMeta,
    children: [
      {
        path: '',
        name: 'companies_dashboard_show',
        component: CompanyDetailView,
        meta: commonMeta,
      },
    ],
  },
];
