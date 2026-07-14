import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
const Automation = () => import('./Index.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/automation'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          redirect: to => {
            return { name: 'automation_list', params: to.params };
          },
        },
        {
          path: 'list',
          name: 'automation_list',
          component: Automation,
          meta: {
            featureFlag: FEATURE_FLAGS.AUTOMATIONS,
            permissions: ['administrator'],
          },
        },
        {
          path: 'touch-plans',
          name: 'automation_touch_plans_index',
          redirect: to => {
            return {
              name: 'captain_assistants_index',
              params: {
                ...to.params,
                navigationPath: 'captain_assistants_follow_ups_index',
              },
              query: to.query,
            };
          },
        },
      ],
    },
  ],
};
