import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
import { frontendURL } from '../../../helper/URLHelper';

const CaptainPageRouteView = () => import('./pages/CaptainPageRouteView.vue');
const AssistantsIndexPage = () => import('./pages/AssistantsIndexPage.vue');
const AssistantEmptyStateIndex = () => import('./assistants/Index.vue');
const AssistantSettingsIndex = () =>
  import('./assistants/settings/Settings.vue');
const AssistantPromptsIndex = () => import('./assistants/prompts/Index.vue');
const AssistantPlaygroundIndex = () =>
  import('./assistants/playground/Index.vue');
const AssistantFollowUpsIndex = () =>
  import('./assistants/followUps/Index.vue');
const DocumentsIndex = () => import('./documents/Index.vue');
const ResponsesIndex = () => import('./responses/Index.vue');
const ResponsesPendingIndex = () => import('./responses/Pending.vue');
const CustomToolsIndex = () => import('./tools/Index.vue');
const ObservabilityIndex = () => import('./observability/Index.vue');
const meta = {
  permissions: ['administrator', 'agent'],
  featureFlag: FEATURE_FLAGS.CAPTAIN,
  installationTypes: [INSTALLATION_TYPES.CLOUD, INSTALLATION_TYPES.ENTERPRISE],
};

const metaV2 = {
  permissions: ['administrator', 'agent'],
  featureFlag: FEATURE_FLAGS.CAPTAIN_V2,
  installationTypes: [INSTALLATION_TYPES.CLOUD, INSTALLATION_TYPES.ENTERPRISE],
};
const manageMeta = {
  ...meta,
  permissions: ['administrator', 'captain_manage'],
};
const manageMetaV2 = {
  ...metaV2,
  permissions: ['administrator', 'captain_manage'],
};

const sharedKnowledgeRoutes = [
  {
    path: frontendURL('accounts/:accountId/captain/faqs'),
    component: ResponsesIndex,
    name: 'captain_assistants_responses_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/documents'),
    component: DocumentsIndex,
    name: 'captain_assistants_documents_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/tools'),
    component: CustomToolsIndex,
    name: 'captain_tools_index',
    meta: metaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/faqs/pending'),
    component: ResponsesPendingIndex,
    name: 'captain_assistants_responses_pending',
    meta,
  },
];

const legacySharedKnowledgeRoutes = [
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/faqs'),
    redirect: to => ({
      name: 'captain_assistants_responses_index',
      params: { accountId: to.params.accountId },
      query: to.query,
    }),
    name: 'captain_assistants_responses_legacy_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/documents'),
    redirect: to => ({
      name: 'captain_assistants_documents_index',
      params: { accountId: to.params.accountId },
      query: to.query,
    }),
    name: 'captain_assistants_documents_legacy_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/tools'),
    redirect: to => ({
      name: 'captain_tools_index',
      params: { accountId: to.params.accountId },
      query: to.query,
    }),
    name: 'captain_tools_legacy_index',
    meta: metaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/faqs/pending'),
    redirect: to => ({
      name: 'captain_assistants_responses_pending',
      params: { accountId: to.params.accountId },
      query: to.query,
    }),
    name: 'captain_assistants_responses_pending_legacy',
    meta,
  },
];

const assistantRoutes = [
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/scenarios'),
    redirect: to => ({
      name: 'captain_assistants_prompts_index',
      params: to.params,
      query: to.query,
    }),
    name: 'captain_assistants_scenarios_index',
    meta: manageMetaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/playground'),
    component: AssistantPlaygroundIndex,
    name: 'captain_assistants_playground_index',
    meta: metaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/channels'),
    redirect: to => ({
      name: 'settings_inbox_list',
      params: { accountId: to.params.accountId },
      query: to.query,
    }),
    name: 'captain_assistants_channels_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/inboxes'),
    redirect: to => ({
      name: 'settings_inbox_list',
      params: { accountId: to.params.accountId },
      query: to.query,
    }),
    name: 'captain_assistants_inboxes_index',
    meta,
  },

  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/settings'),
    component: AssistantSettingsIndex,
    name: 'captain_assistants_settings_index',
    meta: manageMeta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/prompts'),
    component: AssistantPromptsIndex,
    name: 'captain_assistants_prompts_index',
    meta: manageMeta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/follow-ups'),
    component: AssistantFollowUpsIndex,
    name: 'captain_assistants_follow_ups_index',
    meta: manageMetaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/outcomes'),
    redirect: to => ({
      name: 'captain_assistants_settings_index',
      params: to.params,
      query: { ...to.query, tab: 'profile' },
    }),
    name: 'captain_assistants_outcomes_index',
    meta: manageMetaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/access'),
    redirect: to => ({
      name: 'captain_assistants_settings_index',
      params: to.params,
      query: to.query,
    }),
    name: 'captain_assistants_access_index',
    meta: manageMeta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/restrictions'),
    redirect: to => ({
      name: 'captain_assistants_prompts_index',
      params: to.params,
      query: to.query,
    }),
    name: 'captain_assistants_restrictions_index',
    meta: manageMetaV2,
  },
  {
    path: frontendURL(
      'accounts/:accountId/captain/:assistantId/settings/guardrails'
    ),
    redirect: to => ({
      name: 'captain_assistants_restrictions_index',
      params: to.params,
      query: to.query,
    }),
    name: 'captain_assistants_guardrails_index',
    meta: manageMetaV2,
  },
  {
    path: frontendURL(
      'accounts/:accountId/captain/:assistantId/settings/guidelines'
    ),
    redirect: to => ({
      name: 'captain_assistants_prompts_index',
      params: to.params,
      query: to.query,
    }),
    name: 'captain_assistants_guidelines_index',
    meta: manageMetaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/assistants'),
    component: AssistantEmptyStateIndex,
    name: 'captain_assistants_create_index',
    meta: {
      permissions: ['administrator', 'captain_manage'],
      installationTypes: [
        INSTALLATION_TYPES.CLOUD,
        INSTALLATION_TYPES.ENTERPRISE,
      ],
    },
  },
  {
    path: frontendURL('accounts/:accountId/captain/observability'),
    component: ObservabilityIndex,
    name: 'captain_observability_index',
    meta: {
      permissions: ['administrator'],
      featureFlag: FEATURE_FLAGS.CAPTAIN_V2,
      installationTypes: [
        INSTALLATION_TYPES.CLOUD,
        INSTALLATION_TYPES.ENTERPRISE,
      ],
    },
  },
  {
    path: frontendURL('accounts/:accountId/captain/:navigationPath'),
    component: AssistantsIndexPage,
    name: 'captain_assistants_index',
    meta,
  },
];

export const routes = [
  {
    path: frontendURL('accounts/:accountId/captain'),
    component: CaptainPageRouteView,
    redirect: to => {
      return {
        name: 'captain_assistants_index',
        params: {
          navigationPath: 'knowledge_base',
          ...to.params,
        },
      };
    },
    children: [
      ...sharedKnowledgeRoutes,
      ...legacySharedKnowledgeRoutes,
      ...assistantRoutes,
    ],
  },
];
