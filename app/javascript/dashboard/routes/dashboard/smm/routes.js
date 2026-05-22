import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';

const SmmPage = () => import('./SmmPage.vue');

const smmMeta = {
  featureFlag: FEATURE_FLAGS.SMM,
  permissions: ['administrator'],
};

const routeFor = (path, name, section) => ({
  path: frontendURL(`accounts/:accountId/smm/${path}`),
  name,
  component: SmmPage,
  meta: { ...smmMeta, section },
});

export const routes = [
  {
    path: frontendURL('accounts/:accountId/smm'),
    redirect: to => ({ name: 'smm_calendar', params: to.params }),
    meta: smmMeta,
  },
  routeFor('calendar', 'smm_calendar', 'calendar'),
  routeFor('posts', 'smm_posts', 'posts'),
  routeFor('channels', 'smm_channels', 'channels'),
  routeFor('media', 'smm_media', 'media'),
  routeFor('analytics', 'smm_analytics', 'analytics'),
  routeFor('settings', 'smm_settings', 'settings'),
];
