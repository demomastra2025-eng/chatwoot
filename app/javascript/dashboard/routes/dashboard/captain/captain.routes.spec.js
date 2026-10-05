import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { createMemoryHistory, createRouter, RouterView } from 'vue-router';
import { routes } from './captain.routes';
import AssistantsIndexPage from './pages/AssistantsIndexPage.vue';

const mocks = vi.hoisted(() => ({
  assistants: [{ id: 2 }],
  // The loaded assistants: an AI agent and an old internal assistant.
  records: [
    { id: 2, usage_mode: 'external_agent' },
    { id: 9, usage_mode: 'internal_assistant' },
  ],
}));

vi.mock('../../../store', () => ({
  default: {
    state: { captainAssistants: { records: mocks.records } },
    dispatch: vi.fn(() => Promise.resolve()),
  },
}));

vi.mock('vuex', () => ({
  useStore: () => ({
    dispatch: vi.fn(() => Promise.resolve()),
    getters: { 'captainAssistants/getRecords': mocks.assistants },
  }),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: { value: { last_active_assistant_id: 2 } },
  }),
}));

const flattenRoutes = items =>
  items.flatMap(route => [
    route,
    ...(route.children ? flattenRoutes(route.children) : []),
  ]);

const PageStub = defineComponent({
  name: 'CaptainPageStub',
  render: () => h('div'),
});

// The real captain route records (paths, names and redirects) with the lazy
// pages replaced by a stub; the navigation page is the real one, so a sidebar
// target is resolved exactly like in the app.
const componentFor = route => {
  if (route.name === 'captain_assistants_index') return AssistantsIndexPage;
  if (route.children) return RouterView;
  return PageStub;
};

const routerRecords = items =>
  items.map(route => ({
    ...route,
    ...(route.component ? { component: componentFor(route) } : {}),
    ...(route.children ? { children: routerRecords(route.children) } : {}),
  }));

const buildRouter = () =>
  createRouter({
    history: createMemoryHistory(),
    routes: [
      ...routerRecords(routes),
      // Targets outside the captain routes (channel settings).
      {
        path: '/app/accounts/:accountId/settings/inboxes/list',
        name: 'settings_inbox_list',
        component: PageStub,
      },
    ],
  });

describe('captain routes', () => {
  it('exposes a dedicated AI evaluations page', () => {
    const evaluationRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_evaluations_index'
    );

    expect(evaluationRoute).toBeTruthy();
    expect(evaluationRoute.path).toContain('/captain/evaluations');
    expect(evaluationRoute.meta.permissions).toEqual(['administrator']);
  });

  it('exposes the assistant sandbox («Площадка») at the playground route', () => {
    const playgroundRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_assistants_playground_index'
    );

    expect(playgroundRoute).toBeTruthy();
    expect(playgroundRoute.path).toContain('/captain/:assistantId/playground');
    expect(playgroundRoute.component).toBeTypeOf('function');
    expect(playgroundRoute.redirect).toBeUndefined();
  });

  it('lands the «Площадка» sidebar target on the sandbox page, not on the instructions', async () => {
    const router = buildRouter();
    const wrapper = mount(
      { render: () => h(RouterView) },
      {
        global: { plugins: [router] },
      }
    );

    // The sidebar item «Площадка» links here (Sidebar.vue, child «Sandbox»).
    await router.push({
      name: 'captain_assistants_index',
      params: {
        accountId: '1',
        navigationPath: 'captain_assistants_playground_index',
      },
    });
    await flushPromises();
    await flushPromises();

    const { currentRoute } = router;
    expect(currentRoute.value.name).toBe('captain_assistants_playground_index');
    expect(currentRoute.value.name).not.toBe(
      'captain_assistants_prompts_index'
    );
    expect(currentRoute.value.path).toBe(
      '/app/accounts/1/captain/2/playground'
    );
    expect(currentRoute.value.matched.at(-1).components.default).toBe(PageStub);
    wrapper.unmount();
  });

  describe('links to the pages of an assistant', () => {
    const open = async (router, name, assistantId) => {
      await router.push({
        name,
        params: { accountId: '1', assistantId },
      });
      await flushPromises();
      return router.currentRoute.value;
    };

    [
      'captain_assistants_settings_index',
      'captain_assistants_prompts_index',
      'captain_assistants_follow_ups_index',
      'captain_assistants_playground_index',
    ].forEach(name => {
      it(`opens the ${name} page of an AI agent`, async () => {
        const router = buildRouter();

        const route = await open(router, name, '2');

        expect(route.name).toBe(name);
      });

      it(`treats the ${name} link of an internal assistant as a missing agent`, async () => {
        const router = buildRouter();

        const route = await open(router, name, '9');

        expect(route.name).toBe('captain_assistants_create_index');
        expect(route.path).toBe('/app/accounts/1/captain/assistants');
      });
    });

    it('also catches the old redirecting links of an internal assistant', async () => {
      const router = buildRouter();

      const route = await open(router, 'captain_assistants_access_index', '9');

      expect(route.name).toBe('captain_assistants_create_index');
    });
  });

  it('redirects the removed channels page to channel settings', () => {
    const channelsRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_assistants_channels_index'
    );

    expect(channelsRoute).toBeTruthy();
    expect(channelsRoute.path).toContain('/captain/:assistantId/channels');
    expect(channelsRoute.component).toBeUndefined();
    expect(
      channelsRoute.redirect({
        params: { accountId: '1', assistantId: '2' },
        query: { source: 'legacy' },
      })
    ).toEqual({
      name: 'settings_inbox_list',
      params: { accountId: '1' },
      query: { source: 'legacy' },
    });
  });
});
