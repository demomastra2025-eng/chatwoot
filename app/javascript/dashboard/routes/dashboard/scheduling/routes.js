import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';
import { SCHEDULING_ACCESS_PERMISSIONS } from '../../../constants/permissions';

const SchedulingCalendarPage = () =>
  import('./pages/SchedulingCalendarPage.vue');
const SchedulingExceptionsPage = () =>
  import('./pages/SchedulingExceptionsPage.vue');
const SchedulingResourcesPage = () =>
  import('./pages/SchedulingResourcesPage.vue');
const SchedulingServicesPage = () =>
  import('./pages/SchedulingServicesPage.vue');
const schedulingMeta = {
  featureFlag: FEATURE_FLAGS.SCHEDULING,
  permissions: SCHEDULING_ACCESS_PERMISSIONS,
};

const schedulingAdminMeta = {
  featureFlag: FEATURE_FLAGS.SCHEDULING,
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
];
