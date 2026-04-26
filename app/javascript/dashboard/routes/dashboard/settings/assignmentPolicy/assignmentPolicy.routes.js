import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
const SettingsWrapper = () => import('../SettingsWrapper.vue');
const AssignmentPolicyIndex = () => import('./Index.vue');
const AgentAssignmentIndex = () =>
  import('./pages/AgentAssignmentIndexPage.vue');
const AgentAssignmentCreate = () =>
  import('./pages/AgentAssignmentCreatePage.vue');
const AgentAssignmentEdit = () => import('./pages/AgentAssignmentEditPage.vue');
const AgentCapacityIndex = () => import('./pages/AgentCapacityIndexPage.vue');
const AgentCapacityCreate = () => import('./pages/AgentCapacityCreatePage.vue');
const AgentCapacityEdit = () => import('./pages/AgentCapacityEditPage.vue');
export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/assignment-policy'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          redirect: to => {
            return { name: 'assignment_policy_index', params: to.params };
          },
        },
        {
          path: 'index',
          name: 'assignment_policy_index',
          component: AssignmentPolicyIndex,
          meta: {
            featureFlag: FEATURE_FLAGS.ASSIGNMENT_V2,
            permissions: ['administrator'],
          },
        },
        {
          path: 'assignment',
          name: 'agent_assignment_policy_index',
          component: AgentAssignmentIndex,
          meta: {
            featureFlag: FEATURE_FLAGS.ASSIGNMENT_V2,
            permissions: ['administrator'],
          },
        },
        {
          path: 'assignment/create',
          name: 'agent_assignment_policy_create',
          component: AgentAssignmentCreate,
          meta: {
            featureFlag: FEATURE_FLAGS.ASSIGNMENT_V2,
            permissions: ['administrator'],
          },
        },
        {
          path: 'assignment/edit/:id',
          name: 'agent_assignment_policy_edit',
          component: AgentAssignmentEdit,
          meta: {
            featureFlag: FEATURE_FLAGS.ASSIGNMENT_V2,
            permissions: ['administrator'],
          },
        },
        {
          path: 'capacity',
          name: 'agent_capacity_policy_index',
          component: AgentCapacityIndex,
          meta: {
            featureFlag: FEATURE_FLAGS.ADVANCED_ASSIGNMENT,
            permissions: ['administrator'],
          },
        },
        {
          path: 'capacity/create',
          name: 'agent_capacity_policy_create',
          component: AgentCapacityCreate,
          meta: {
            featureFlag: FEATURE_FLAGS.ADVANCED_ASSIGNMENT,
            permissions: ['administrator'],
          },
        },
        {
          path: 'capacity/edit/:id',
          name: 'agent_capacity_policy_edit',
          component: AgentCapacityEdit,
          meta: {
            featureFlag: FEATURE_FLAGS.ADVANCED_ASSIGNMENT,
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
