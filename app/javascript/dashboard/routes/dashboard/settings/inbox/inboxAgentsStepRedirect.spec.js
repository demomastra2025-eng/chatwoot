import { describe, expect, it } from 'vitest';
import { createMemoryHistory, createRouter } from 'vue-router';
import inboxRoutes from './inbox.routes';
import inboxDialogRoutes from './inboxDialog.routes';
import {
  INBOX_FLOW_ROUTE_NAMES,
  redirectLegacyAgentsStep,
} from './helpers/inboxFlowRoutes';

// OneLink does not ask to choose agents for a new channel. The old
// `:inbox_id/agents` step must never render (not even for a moment): every
// channel goes from creation straight to the finish step, and old links or
// OAuth returns that still point at `/agents` are redirected before any
// component is mounted.

const StubComponent = { render: () => null };

const stubComponents = records =>
  records.map(record => {
    const next = { ...record };
    if (next.component) next.component = StubComponent;
    if (next.children) next.children = stubComponents(next.children);
    return next;
  });

const collectRecords = records =>
  records.flatMap(record => [record, ...collectRecords(record.children || [])]);

const buildRouter = (...routeSets) => {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: stubComponents(routeSets.flatMap(set => set.routes)),
  });
  const visited = [];
  router.beforeEach(to => {
    visited.push(to.name);
  });
  return { router, visited };
};

const channelSources = import.meta.glob(
  ['./InboxChannels.vue', './channels/**/*.vue'],
  { query: '?raw', import: 'default', eager: true }
);

describe('inbox creation: legacy agents step', () => {
  it.each([
    ['settings', inboxRoutes, INBOX_FLOW_ROUTE_NAMES.settings],
    ['dialog', inboxDialogRoutes, INBOX_FLOW_ROUTE_NAMES.dialog],
  ])(
    'the %s agents route is a redirect without a component',
    (_, routeSet, flowRoutes) => {
      const record = collectRecords(routeSet.routes).find(
        item => item.name === flowRoutes.agents
      );

      expect(record).toBeDefined();
      expect(record.path).toBe(':inbox_id/agents');
      expect(typeof record.redirect).toBe('function');
      expect(record.component).toBeUndefined();
      expect(record.components).toBeUndefined();
    }
  );

  it('builds the finish location from the agents route', () => {
    const redirect = redirectLegacyAgentsStep(INBOX_FLOW_ROUTE_NAMES.settings);

    expect(
      redirect({
        params: { accountId: '7', inbox_id: '42' },
        query: { channel_type: 'whatsapp_web' },
        hash: '#qr',
      })
    ).toEqual({
      name: 'settings_inbox_finish',
      params: { accountId: '7', inbox_id: '42' },
      query: { channel_type: 'whatsapp_web' },
      hash: '#qr',
    });
  });

  it('sends an old settings link straight to finish without visiting agents', async () => {
    const { router, visited } = buildRouter(inboxRoutes);

    await router.push(
      '/app/accounts/7/settings/inboxes/new/42/agents?channel_type=whatsapp_web'
    );

    const route = router.currentRoute.value;
    expect(route.name).toBe('settings_inbox_finish');
    expect(route.params).toMatchObject({ accountId: '7', inbox_id: '42' });
    expect(route.query).toEqual({ channel_type: 'whatsapp_web' });
    expect(route.fullPath).not.toContain('/agents');
    expect(visited).toEqual(['settings_inbox_finish']);
  });

  it('sends an OAuth return to the agents url straight to finish', async () => {
    const { router, visited } = buildRouter(inboxRoutes);

    await router.push('/app/accounts/3/settings/inboxes/new/15/agents');

    expect(router.currentRoute.value.name).toBe('settings_inbox_finish');
    expect(router.currentRoute.value.params.inbox_id).toBe('15');
    expect(visited).toEqual(['settings_inbox_finish']);
  });

  it('redirects a push by the old route name too', async () => {
    const { router, visited } = buildRouter(inboxRoutes);

    await router.push({
      name: 'settings_inboxes_add_agents',
      params: { accountId: 5, inbox_id: 9 },
      query: { provider: 'sipuni' },
    });

    const route = router.currentRoute.value;
    expect(route.name).toBe('settings_inbox_finish');
    expect(route.params).toMatchObject({ accountId: '5', inbox_id: '9' });
    expect(route.query).toEqual({ provider: 'sipuni' });
    expect(visited).toEqual(['settings_inbox_finish']);
  });

  it('keeps the dialog flow inside the dialog finish step', async () => {
    const { router, visited } = buildRouter(inboxDialogRoutes);

    await router.push('/app/accounts/7/dialog/inboxes/new/42/agents');

    const route = router.currentRoute.value;
    expect(route.name).toBe('dialog_inbox_finish');
    expect(route.params).toMatchObject({ accountId: '7', inbox_id: '42' });
    expect(route.meta.inboxFlow).toBe('dialogs');
    expect(visited).toEqual(['dialog_inbox_finish']);
  });
});

describe('inbox creation: channels skip the agents step', () => {
  it('scans the channel forms and the wizard', () => {
    const paths = Object.keys(channelSources);

    expect(paths).toContain('./InboxChannels.vue');
    expect(paths).toContain('./channels/Website.vue');
    expect(paths).toContain('./channels/Voice.vue');
    expect(paths.length).toBeGreaterThan(15);
  });

  it.each(Object.keys(channelSources))(
    '%s never navigates to the agents step',
    path => {
      expect(channelSources[path]).not.toMatch(
        /FlowRouteName\([^)]*['"]agents['"]\)/
      );
      expect(channelSources[path]).not.toMatch(/_add_agents/);
    }
  );

  it('does not show an agents step in the wizard sidebar', () => {
    expect(channelSources['./InboxChannels.vue']).not.toMatch(/AGENT|agents/);
  });

  it('has no agents screen component left to render', () => {
    const screens = import.meta.glob('./AddAgents.vue');

    expect(Object.keys(screens)).toEqual([]);
  });
});
