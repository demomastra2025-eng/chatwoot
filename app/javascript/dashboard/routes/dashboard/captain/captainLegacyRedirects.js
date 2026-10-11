// Old links into the AI section (bookmarks, links in notes and messages, the
// former sidebar targets) keep working for one release: each one lands on the
// page of the «ИИ-агенты» section that replaced it. All helpers are pure and
// keep the query of the old link.
export const CAPTAIN_AGENTS_ROUTE = 'captain_agents_index';
export const CAPTAIN_AGENT_ROUTE = 'captain_agent_show';
export const CAPTAIN_CHANNELS_ROUTE = 'captain_channels_index';
export const CAPTAIN_AI_SETTINGS_ROUTE = 'captain_ai_settings_index';

// Tabs of the agent page (query param `tab`; the instruction tab is the
// default and is never written to the URL).
export const AGENT_PAGE_TABS = Object.freeze({
  CHECK: 'check',
  FOLLOW_UPS: 'follow-ups',
});

// Sections of the AI settings page (DOM ids).
export const AI_SETTINGS_SECTION_HASHES = Object.freeze({
  SAFETY: '#safety',
  HANDOFF: '#handoff',
});

// captain/:navigationPath used to resolve a short name or a route name.
const NAVIGATION_PATH_ROUTES = new Map([
  ['knowledge_base', 'captain_assistants_responses_index'],
  ['documents', 'captain_assistants_documents_index'],
  ['tools', 'captain_tools_index'],
  ['channels', CAPTAIN_CHANNELS_ROUTE],
]);

// The former sidebar targets passed route names as the navigation path.
const NAVIGATION_PATH_ALIASES = new Map([
  ['captain_assistants_responses_index', 'knowledge_base'],
  ['captain_assistants_documents_index', 'documents'],
  ['captain_tools_index', 'tools'],
  ['captain_assistants_channels_index', 'channels'],
  ['captain_assistants_inboxes_index', 'channels'],
]);

const accountParams = to => ({ accountId: to.params?.accountId });

const isAgentId = value => /^\d+$/.test(String(value ?? ''));

export const navigationPathRouteName = navigationPath => {
  const path = NAVIGATION_PATH_ALIASES.get(navigationPath) || navigationPath;
  return NAVIGATION_PATH_ROUTES.get(path) || CAPTAIN_AGENTS_ROUTE;
};

export const redirectToAgents = to => ({
  name: CAPTAIN_AGENTS_ROUTE,
  params: accountParams(to),
  query: to.query,
});

export const redirectNavigationPath = to => ({
  name: navigationPathRouteName(to.params?.navigationPath),
  params: accountParams(to),
  query: to.query,
});

// An old per-agent page opens the agent page (optionally on a tab). A link
// whose agent id is not a number cannot name an agent: it opens the gallery.
export const redirectToAgentPage =
  (tab = '') =>
  to => {
    if (!isAgentId(to.params?.assistantId)) return redirectToAgents(to);

    return {
      name: CAPTAIN_AGENT_ROUTE,
      params: {
        accountId: to.params.accountId,
        assistantId: String(to.params.assistantId),
      },
      query: tab ? { ...(to.query || {}), tab } : to.query,
    };
  };

export const redirectToChannels = to => ({
  name: CAPTAIN_CHANNELS_ROUTE,
  params: accountParams(to),
  query: to.query,
});

export const redirectToAiSettings =
  (hash = '') =>
  to => ({
    name: CAPTAIN_AI_SETTINGS_ROUTE,
    params: accountParams(to),
    query: to.query,
    ...(hash ? { hash } : {}),
  });
