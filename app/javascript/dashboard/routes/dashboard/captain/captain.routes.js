import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
import { frontendURL } from '../../../helper/URLHelper';
import { redirectHiddenAssistant } from './assistantRouteGuard';
import {
  AGENT_PAGE_TABS,
  AI_SETTINGS_SECTION_HASHES,
  redirectNavigationPath,
  redirectToAgentPage,
  redirectToAgents,
  redirectToAiSettings,
  redirectToChannels,
} from './captainLegacyRedirects';

const CaptainPageRouteView = () => import('./pages/CaptainPageRouteView.vue');
const AgentsIndex = () => import('./agents/Index.vue');
const AgentPage = () => import('./agents/AgentPage.vue');
const ChannelsIndex = () => import('./channels/Index.vue');
const AiSettingsIndex = () => import('./aiSettings/Index.vue');
const DocumentsIndex = () => import('./documents/Index.vue');
const ResponsesIndex = () => import('./responses/Index.vue');
const ResponsesPendingIndex = () => import('./responses/Pending.vue');
const CustomToolsIndex = () => import('./tools/Index.vue');
const ObservabilityIndex = () => import('./observability/Index.vue');

const installationTypes = [
  INSTALLATION_TYPES.CLOUD,
  INSTALLATION_TYPES.ENTERPRISE,
];

const meta = {
  permissions: ['administrator', 'agent'],
  featureFlag: FEATURE_FLAGS.CAPTAIN,
  installationTypes,
};

const metaV2 = {
  permissions: ['administrator', 'agent'],
  featureFlag: FEATURE_FLAGS.CAPTAIN_V2,
  installationTypes,
};

// The pages that configure all agents at once are for administrators.
const adminMeta = {
  permissions: ['administrator'],
  featureFlag: FEATURE_FLAGS.CAPTAIN,
  installationTypes,
};

// The «ИИ-агенты» section: the gallery, one page per agent and the global
// pages (channels, settings, logs).
const agentRoutes = [
  {
    // No feature flag: without Captain the gallery shows the paywall.
    path: frontendURL('accounts/:accountId/captain/agents'),
    component: AgentsIndex,
    name: 'captain_agents_index',
    meta: {
      permissions: ['administrator', 'agent'],
      installationTypes,
    },
  },
  {
    path: frontendURL('accounts/:accountId/captain/agents/:assistantId(\\d+)'),
    component: AgentPage,
    name: 'captain_agent_show',
    meta,
    beforeEnter: redirectHiddenAssistant,
  },
  {
    path: frontendURL('accounts/:accountId/captain/channels'),
    component: ChannelsIndex,
    name: 'captain_channels_index',
    meta: adminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/settings'),
    component: AiSettingsIndex,
    name: 'captain_ai_settings_index',
    meta: adminMeta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/observability'),
    component: ObservabilityIndex,
    name: 'captain_observability_index',
    meta: {
      permissions: ['administrator'],
      featureFlag: FEATURE_FLAGS.CAPTAIN_V2,
      installationTypes,
    },
  },
];

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

// Former per-agent pages and the old list: kept as redirect records (with
// their old names) for one release, see captainLegacyRedirects.js.
const legacyAgentRoutes = [
  {
    path: frontendURL('accounts/:accountId/captain/assistants'),
    redirect: redirectToAgents,
    name: 'captain_assistants_create_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/scenarios'),
    redirect: redirectToAgents,
    name: 'captain_assistants_scenarios_index',
    meta: metaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/settings'),
    redirect: redirectToAgentPage(),
    name: 'captain_assistants_settings_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/prompts'),
    redirect: redirectToAgentPage(),
    name: 'captain_assistants_prompts_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/restrictions'),
    redirect: redirectToAgentPage(),
    name: 'captain_assistants_restrictions_index',
    meta: metaV2,
  },
  {
    path: frontendURL(
      'accounts/:accountId/captain/:assistantId/settings/guidelines'
    ),
    redirect: redirectToAgentPage(),
    name: 'captain_assistants_guidelines_index',
    meta: metaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/access'),
    redirect: redirectToAgentPage(),
    name: 'captain_assistants_access_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/playground'),
    redirect: redirectToAgentPage(AGENT_PAGE_TABS.CHECK),
    name: 'captain_assistants_playground_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/follow-ups'),
    redirect: redirectToAgentPage(AGENT_PAGE_TABS.FOLLOW_UPS),
    name: 'captain_assistants_follow_ups_index',
    meta: metaV2,
  },
  {
    path: frontendURL(
      'accounts/:accountId/captain/:assistantId/settings/guardrails'
    ),
    redirect: redirectToAiSettings(AI_SETTINGS_SECTION_HASHES.SAFETY),
    name: 'captain_assistants_guardrails_index',
    meta: metaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/outcomes'),
    redirect: redirectToAiSettings(AI_SETTINGS_SECTION_HASHES.HANDOFF),
    name: 'captain_assistants_outcomes_index',
    meta: metaV2,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/channels'),
    redirect: redirectToChannels,
    name: 'captain_assistants_channels_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/captain/:assistantId/inboxes'),
    redirect: redirectToChannels,
    name: 'captain_assistants_inboxes_index',
    meta,
  },
  {
    // The former redirector page: short names and old sidebar targets.
    path: frontendURL('accounts/:accountId/captain/:navigationPath'),
    redirect: redirectNavigationPath,
    name: 'captain_assistants_index',
    meta,
  },
];

export const routes = [
  {
    path: frontendURL('accounts/:accountId/captain'),
    component: CaptainPageRouteView,
    redirect: redirectToAgents,
    children: [
      ...agentRoutes,
      ...sharedKnowledgeRoutes,
      ...legacySharedKnowledgeRoutes,
      ...legacyAgentRoutes,
    ],
  },
];
