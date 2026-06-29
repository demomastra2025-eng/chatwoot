import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';

const SmmPage = () => import('./SmmPage.vue');
const LeadFormsPage = () => import('../settings/leadForms/Index.vue');

const smmMeta = {
  featureFlag: FEATURE_FLAGS.SMM,
  permissions: ['administrator'],
};

const routeFor = (path, name, section, component = SmmPage) => ({
  path: frontendURL(`accounts/:accountId/smm/${path}`),
  name,
  component,
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
  routeFor('lead-forms', 'lead_forms_index', 'lead_forms', LeadFormsPage),
  routeFor('media', 'smm_media', 'media'),
  routeFor('analytics', 'smm_analytics', 'analytics'),
  routeFor('settings', 'smm_settings', 'settings'),
];
