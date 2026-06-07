import { createRouter, createWebHistory } from 'vue-router';

import { frontendURL } from '../helper/URLHelper';
import dashboard from './dashboard/dashboard.routes';
import store from 'dashboard/store';
import { validateLoggedInRoutes } from '../helper/routeHelpers';

const routes = [...dashboard.routes];

routes.unshift({
  path: '/',
  redirect: frontendURL('login'),
});

export const router = createRouter({ history: createWebHistory(), routes });

const trackPageView = to => {
  import('../helper/AnalyticsHelper')
    .then(({ default: AnalyticsHelper }) => {
      AnalyticsHelper.page(to.name || '', {
        path: to.path,
        name: to.name,
      });
    })
    .catch(() => {});
};

const getRouteAccountFeatureSource = async to => {
  if (!to.meta?.featureFlag || !to.params?.accountId) {
    return null;
  }

  const getAccount = store.getters['accounts/getAccount'];
  const resolveAccount = () =>
    typeof getAccount === 'function' ? getAccount(to.params.accountId) : null;

  let account = resolveAccount();
  if (account?.id || account?.features) {
    return account;
  }

  await store.dispatch('accounts/get');
  account = resolveAccount();
  return account;
};

export const validateAuthenticateRoutePermission = async (to, next) => {
  const { isLoggedIn, getCurrentUser: user } = store.getters;

  if (!isLoggedIn) {
    window.location.assign('/app/login');
    return '';
  }

  const { accounts = [], account_id: accountId } = user;

  if (!accounts.length) {
    if (to.name === 'no_accounts') {
      return next();
    }
    return next(frontendURL('no-accounts'));
  }

  if (to.name === 'no_accounts' || !to.name) {
    return next(frontendURL(`accounts/${accountId}/dashboard`));
  }

  const accountFeatureSource = to.meta?.featureFlag
    ? await getRouteAccountFeatureSource(to)
    : null;
  const nextRoute = validateLoggedInRoutes(
    to,
    store.getters.getCurrentUser,
    accountFeatureSource
  );
  return nextRoute ? next(frontendURL(nextRoute)) : next();
};

export const initalizeRouter = () => {
  const userAuthentication = store.dispatch('setUser');

  router.beforeEach((to, _from, next) => {
    trackPageView(to);

    userAuthentication.then(() => {
      return validateAuthenticateRoutePermission(to, next, store);
    });
  });
};

export default router;
