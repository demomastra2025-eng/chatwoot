import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { createMemoryHistory, createRouter, RouterView } from 'vue-router';
import { routes } from './captain.routes';
import AssistantsIndexPage from './pages/AssistantsIndexPage.vue';

const mocks = vi.hoisted(() => ({
  assistants: [{ id: 2 }],
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
