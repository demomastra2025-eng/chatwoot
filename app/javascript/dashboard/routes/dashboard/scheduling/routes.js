import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';

import SchedulingCalendarPage from './pages/SchedulingCalendarPage.vue';
import SchedulingExceptionsPage from './pages/SchedulingExceptionsPage.vue';
import SchedulingKassaPage from './pages/SchedulingKassaPage.vue';
import SchedulingResourcesPage from './pages/SchedulingResourcesPage.vue';
import SchedulingServicesPage from './pages/SchedulingServicesPage.vue';

const schedulingMeta = {
  featureFlag: FEATURE_FLAGS.SCHEDULING,
  permissions: ['administrator', 'agent', 'custom_role'],
};

const schedulingAdminMeta = {
  featureFlag: FEATURE_FLAGS.SCHEDULING,
  permissions: ['administrator'],
};

const schedulingFinanceMeta = {
  featureFlag: FEATURE_FLAGS.SCHEDULING_FINANCE,
  permissions: ['administrator'],
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
    meta: schedulingAdminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/scheduling/exceptions'),
    name: 'scheduling_exceptions',
    component: SchedulingExceptionsPage,
    meta: schedulingAdminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/scheduling/kassa'),
    name: 'scheduling_kassa',
    component: SchedulingKassaPage,
    meta: schedulingFinanceMeta,
  },
];
