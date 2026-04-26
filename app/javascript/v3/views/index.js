import { createRouter, createWebHistory } from 'vue-router';

import routes from './routes';
import { validateRouteAccess } from '../helpers/RouteHelper';

export const router = createRouter({ history: createWebHistory(), routes });

const sensitiveRouteNames = ['auth_password_edit'];

const trackPageView = to => {
  import('dashboard/helper/AnalyticsHelper')
    .then(({ default: AnalyticsHelper }) => {
      AnalyticsHelper.page(to.name || '', {
        path: to.path,
        name: to.name,
      });
    })
    .catch(() => {});
};

export const initalizeRouter = () => {
  router.beforeEach((to, _, next) => {
    if (!sensitiveRouteNames.includes(to.name)) {
      trackPageView(to);
    }

    return validateRouteAccess(to, next, window.chatwootConfig);
  });
};

export default router;
