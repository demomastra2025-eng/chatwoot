import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { createMemoryHistory, createRouter, RouterView } from 'vue-router';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { routes } from './captain.routes';
import { redirectHiddenAssistant } from './assistantRouteGuard';

const mocks = vi.hoisted(() => ({
  // The loaded assistants: an AI agent and an old internal assistant.
  records: [
    { id: 2, usage_mode: 'external_agent' },
    { id: 9, usage_mode: 'internal_assistant' },
  ],
  dispatch: vi.fn(() => Promise.resolve()),
}));

vi.mock('../../../store', () => ({
  default: {
    state: { captainAssistants: { records: mocks.records } },
    dispatch: (...args) => mocks.dispatch(...args),
  },
}));

const flattenRoutes = items =>
  items.flatMap(route => [
    route,
    ...(route.children ? flattenRoutes(route.children) : []),
  ]);

const findRoute = name =>
  flattenRoutes(routes).find(route => route.name === name);

const PageStub = defineComponent({
  name: 'CaptainPageStub',
  render: () => h('div'),
});

// The real captain route records (paths, names, guards and redirects) with
// the lazy pages replaced by a stub.
const routerRecords = items =>
  items.map(route => ({
    ...route,
    ...(route.component
      ? { component: route.children ? RouterView : PageStub }
      : {}),
    ...(route.children ? { children: routerRecords(route.children) } : {}),
  }));

const buildRouter = () =>
  createRouter({
    history: createMemoryHistory(),
    routes: routerRecords(routes),
  });

const open = async location => {
  const router = buildRouter();
  await router.push(location);
  return router.currentRoute.value;
};

const BASE = '/app/accounts/1/captain';

describe('captain routes', () => {
  beforeEach(() => {
    mocks.dispatch.mockClear();
  });

  describe('pages of the «ИИ-агенты» section', () => {
    it('registers the agents gallery without a feature flag (the page shows the paywall)', () => {
      const route = findRoute('captain_agents_index');

      expect(route.path).toBe('/app/accounts/:accountId/captain/agents');
      expect(route.component).toBeTypeOf('function');
      expect(route.redirect).toBeUndefined();
      expect(route.meta.permissions).toEqual(['administrator', 'agent']);
      expect(route.meta.featureFlag).toBeUndefined();
      expect(route.meta.installationTypes).toHaveLength(2);
    });

    it('registers the agent page with a numeric id and the hidden-assistant guard', () => {
      const route = findRoute('captain_agent_show');

      expect(route.path).toBe(
        '/app/accounts/:accountId/captain/agents/:assistantId(\\d+)'
      );
      expect(route.component).toBeTypeOf('function');
      expect(route.beforeEnter).toBe(redirectHiddenAssistant);
      expect(route.meta.permissions).toEqual(['administrator', 'agent']);
      expect(route.meta.featureFlag).toBe(FEATURE_FLAGS.CAPTAIN);
    });

    it.each([
      ['captain_channels_index', '/app/accounts/:accountId/captain/channels'],
      [
        'captain_ai_settings_index',
        '/app/accounts/:accountId/captain/settings',
      ],
    ])('registers the administrator page %s', (name, path) => {
      const route = findRoute(name);

      expect(route.path).toBe(path);
      expect(route.component).toBeTypeOf('function');
      expect(route.meta.permissions).toEqual(['administrator']);
      expect(route.meta.featureFlag).toBe(FEATURE_FLAGS.CAPTAIN);
    });

    it.each([
      [`${BASE}/agents`, 'captain_agents_index'],
      [`${BASE}/agents/2`, 'captain_agent_show'],
      [`${BASE}/channels`, 'captain_channels_index'],
      [`${BASE}/settings`, 'captain_ai_settings_index'],
      [`${BASE}/faqs`, 'captain_assistants_responses_index'],
      [`${BASE}/faqs/pending`, 'captain_assistants_responses_pending'],
      [`${BASE}/documents`, 'captain_assistants_documents_index'],
      [`${BASE}/tools`, 'captain_tools_index'],
      [`${BASE}/observability`, 'captain_observability_index'],
    ])('opens %s as the page %s', async (path, name) => {
      const route = await open(path);

      expect(route.name).toBe(name);
      expect(route.matched.at(-1).components.default).toBe(PageStub);
    });

    it('opens the agent page of an AI agent', async () => {
      const route = await open({
        name: 'captain_agent_show',
        params: { accountId: '1', assistantId: '2' },
        query: { tab: 'check' },
      });

      expect(route.path).toBe(`${BASE}/agents/2`);
      expect(route.params.assistantId).toBe('2');
      expect(route.query).toEqual({ tab: 'check' });
    });

    it('sends the agent page of an internal assistant to the gallery', async () => {
      const route = await open(`${BASE}/agents/9`);

      expect(route.name).toBe('captain_agents_index');
      expect(route.path).toBe(`${BASE}/agents`);
    });
  });

  describe('legacy links', () => {
    it('opens the gallery from the section root', async () => {
      const route = await open(BASE);

      expect(route.name).toBe('captain_agents_index');
    });

    it('opens the gallery from the old agent list and keeps the query', async () => {
      const route = await open(`${BASE}/assistants?source=legacy`);

      expect(route.name).toBe('captain_agents_index');
      expect(route.query).toEqual({ source: 'legacy' });
    });

    it('opens the gallery from the former scenarios page', async () => {
      const route = await open(`${BASE}/2/scenarios`);

      expect(route.name).toBe('captain_agents_index');
    });

    it.each([
      'settings',
      'prompts',
      'restrictions',
      'settings/guidelines',
      'access',
    ])(
      'opens the instruction tab of the agent page from /:assistantId/%s',
      async page => {
        const route = await open(`${BASE}/2/${page}?source=legacy`);

        expect(route.name).toBe('captain_agent_show');
        expect(route.path).toBe(`${BASE}/agents/2`);
        expect(route.query).toEqual({ source: 'legacy' });
      }
    );

    it('opens the «Проверка» tab from the former playground page', async () => {
      const route = await open(`${BASE}/2/playground?source=legacy`);

      expect(route.name).toBe('captain_agent_show');
      expect(route.params.assistantId).toBe('2');
      expect(route.query).toEqual({ source: 'legacy', tab: 'check' });
    });

    it('opens the «Дожимы» tab from the former follow-ups page', async () => {
      const route = await open(`${BASE}/2/follow-ups`);

      expect(route.name).toBe('captain_agent_show');
      expect(route.query).toEqual({ tab: 'follow-ups' });
    });

    it.each([
      ['settings/guardrails', '#safety'],
      ['outcomes', '#handoff'],
    ])(
      'opens the AI settings section from /:assistantId/%s',
      async (page, hash) => {
        const route = await open(`${BASE}/2/${page}?source=legacy`);

        expect(route.name).toBe('captain_ai_settings_index');
        expect(route.hash).toBe(hash);
        expect(route.query).toEqual({ source: 'legacy' });
      }
    );

    it.each(['channels', 'inboxes'])(
      'opens the channels page from /:assistantId/%s',
      async page => {
        const route = await open(`${BASE}/2/${page}`);

        expect(route.name).toBe('captain_channels_index');
      }
    );

    it('keeps the old route names on the redirect records', () => {
      [
        'captain_assistants_index',
        'captain_assistants_create_index',
        'captain_assistants_scenarios_index',
        'captain_assistants_settings_index',
        'captain_assistants_prompts_index',
        'captain_assistants_restrictions_index',
        'captain_assistants_guidelines_index',
        'captain_assistants_access_index',
        'captain_assistants_playground_index',
        'captain_assistants_follow_ups_index',
        'captain_assistants_guardrails_index',
        'captain_assistants_outcomes_index',
        'captain_assistants_channels_index',
        'captain_assistants_inboxes_index',
      ].forEach(name => {
        const route = findRoute(name);

        expect(route, name).toBeTruthy();
        expect(route.redirect, name).toBeTypeOf('function');
        expect(route.component, name).toBeUndefined();
      });
    });

    it('treats an old link of an internal assistant as a missing agent', async () => {
      const route = await open(`${BASE}/9/access`);

      expect(route.name).toBe('captain_agents_index');
    });

    it('resolves a named link to an old page of an agent', async () => {
      const route = await open({
        name: 'captain_assistants_playground_index',
        params: { accountId: '1', assistantId: '2' },
      });

      expect(route.name).toBe('captain_agent_show');
      expect(route.query).toEqual({ tab: 'check' });
    });

    it.each([
      ['knowledge_base', 'captain_assistants_responses_index'],
      ['documents', 'captain_assistants_documents_index'],
      ['tools', 'captain_tools_index'],
      ['channels', 'captain_channels_index'],
      [
        'captain_assistants_responses_index',
        'captain_assistants_responses_index',
      ],
      ['captain_assistants_playground_index', 'captain_agents_index'],
      ['anything', 'captain_agents_index'],
    ])(
      'resolves the former navigation path %s to %s',
      async (navigationPath, name) => {
        const route = await open({
          name: 'captain_assistants_index',
          params: { accountId: '1', navigationPath },
        });

        expect(route.name).toBe(name);
      }
    );
  });
});
