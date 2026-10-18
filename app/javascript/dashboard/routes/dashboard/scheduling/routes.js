import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { frontendURL } from 'dashboard/helper/URLHelper';

const SchedulingCalendarPage = () =>
  import('./pages/SchedulingCalendarPage.vue');
const SchedulingResourcesPage = () =>
  import('./pages/SchedulingResourcesPage.vue');
const SchedulingServicesPage = () =>
  import('./pages/SchedulingServicesPage.vue');
const SchedulingProductsPage = () =>
  import('./pages/SchedulingProductsPage.vue');
const SchedulingExceptionsPage = () =>
  import('./pages/SchedulingExceptionsPage.vue');
const SchedulingRemindersPage = () =>
  import('./pages/SchedulingRemindersPage.vue');

const schedulingMeta = {
  featureFlag: FEATURE_FLAGS.SCHEDULING,
  permissions: ['administrator', 'agent', 'custom_role'],
};

const schedulingAdminMeta = {
  featureFlag: FEATURE_FLAGS.SCHEDULING,
  permissions: ['administrator'],
};

const catalogAdminMeta = {
  permissions: ['administrator', 'agent', 'custom_role'],
};

export const routes = [
  {
    path: frontendURL('accounts/:accountId/scheduling'),
    redirect: to => ({
      name: 'scheduling_calendar',
      params: to.params,
    }),
    meta: schedulingMeta,
  },
  {
    path: frontendURL('accounts/:accountId/scheduling/calendar'),
    name: 'scheduling_calendar',
    component: SchedulingCalendarPage,
    meta: schedulingMeta,
  },
  {
    path: frontendURL('accounts/:accountId/scheduling/resources'),
    name: 'scheduling_resources',
    component: SchedulingResourcesPage,
    meta: schedulingAdminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/scheduling/services'),
    name: 'scheduling_services',
    component: SchedulingServicesPage,
    meta: catalogAdminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/catalog'),
    redirect: to => ({
      name: 'catalog_products',
      params: to.params,
    }),
    meta: catalogAdminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/catalog/products'),
    name: 'catalog_products',
    component: SchedulingProductsPage,
    meta: catalogAdminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/catalog/services'),
    name: 'catalog_services',
    component: SchedulingServicesPage,
    meta: catalogAdminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/scheduling/exceptions'),
    name: 'scheduling_exceptions',
    component: SchedulingExceptionsPage,
    meta: schedulingAdminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/scheduling/reminders'),
    name: 'scheduling_reminders',
    component: SchedulingRemindersPage,
    meta: schedulingAdminMeta,
  },
];
