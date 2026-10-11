/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h, nextTick } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

import assistantStore from 'dashboard/store/captain/assistant';

const mocks = vi.hoisted(() => ({
  records: [],
  isAdmin: true,
  paywall: false,
  matrix: null,
  push: vi.fn(),
  dispatch: vi.fn(),
  matrixFetch: vi.fn(),
  setActive: vi.fn(),
  summary: vi.fn(),
  dialogOpen: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: mocks.push }),
  useRoute: () => ({ params: { accountId: '1' } }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key => {
    if (key === 'captainAssistants/getRecords') {
      // The real getter of the assistant store decides who is listed.
      return computed(() =>
        assistantStore.getters.getRecords({ records: mocks.records })
      );
    }
    if (key === 'inboxes/getInboxes') return computed(() => []);
    return computed(() => ({ fetchingList: false }));
  },
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: () => mocks.isAdmin,
    shouldShowPaywall: () => mocks.paywall,
  }),
}));

vi.mock('dashboard/store/captain/channelMatrix', () => ({
  useCaptainChannelMatrixStore: () => ({
    get getMatrix() {
      return mocks.matrix;
    },
    fetch: (...args) => mocks.matrixFetch(...args),
  }),
}));

vi.mock('dashboard/helper/captainChannelMatrix', () => ({
  agentChannelSummary: (...args) => mocks.summary(...args),
}));

vi.mock('dashboard/components-next/captain/agent/useAgentActiveToggle', () => ({
  useAgentActiveToggle: () => ({
    setActive: (...args) => mocks.setActive(...args),
    isToggling: () => false,
  }),
}));

// Mirrors PageLayout: the paywall replaces the body, the default slot stays.
vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    props: { isFetching: { type: Boolean, default: false } },
    setup(props, { slots }) {
      return () =>
        h('div', [
          mocks.paywall || props.isFetching ? null : slots.body?.(),
          mocks.paywall ? slots.paywall?.() : null,
          slots.default?.(),
        ]);
    },
  }),
}));

vi.mock('dashboard/components-next/captain/pageComponents/Paywall.vue', () => ({
  default: defineComponent({
    name: 'CaptainPaywall',
    setup: () => () => h('div', { 'data-testid': 'paywall' }),
  }),
}));

vi.mock('dashboard/components-next/captain/agent/AgentGalleryCard.vue', () => ({
  default: defineComponent({
    name: 'AgentGalleryCard',
    props: {
      assistant: { type: Object, required: true },
      stats: { type: Object, default: null },
      canToggle: Boolean,
      toggling: Boolean,
    },
    emits: ['open', 'toggle-active'],
    setup(props) {
      return () =>
        h('div', { 'data-testid': 'agent-card' }, props.assistant.name);
    },
  }),
}));

vi.mock('dashboard/components-next/captain/agent/AgentNewTile.vue', () => ({
  default: defineComponent({
    name: 'AgentNewTile',
    emits: ['click'],
    setup(_props, { emit }) {
      return () =>
        h('button', {
          'data-testid': 'agent-new-tile',
          onClick: () => emit('click'),
        });
    },
  }),
}));

vi.mock(
  'dashboard/components-next/captain/agent/CreateAgentDialog.vue',
  () => ({
    default: defineComponent({
      name: 'CreateAgentDialog',
      emits: ['created', 'close'],
      setup(_props, { expose }) {
        expose({ dialogRef: { open: mocks.dialogOpen } });
        return () => h('div', { 'data-testid': 'create-agent-dialog' });
      },
    }),
  })
);

const { default: AgentsIndex } = await import('./Index.vue');

const mountPage = async () => {
  const wrapper = mount(AgentsIndex);
  await flushPromises();
  return wrapper;
};

const cardNames = wrapper =>
  wrapper.findAll('[data-testid="agent-card"]').map(card => card.text());

const agents = [
  { id: 3, name: 'Мөлдір', usage_mode: 'external_agent', active: true },
  { id: 9, name: 'Арман', usage_mode: 'external_agent', active: true },
  { id: 4, name: 'Бота', usage_mode: 'external_agent', active: false },
];
const helper = { id: 5, name: 'Team helper', usage_mode: 'internal_assistant' };

describe('Captain agents gallery', () => {
  beforeEach(() => {
    mocks.records = [];
    mocks.isAdmin = true;
    mocks.paywall = false;
    mocks.matrix = null;
    mocks.push.mockReset();
    mocks.dispatch.mockReset();
    mocks.dispatch.mockResolvedValue([]);
    mocks.matrixFetch.mockReset();
    mocks.matrixFetch.mockResolvedValue(null);
    mocks.setActive.mockReset();
    mocks.dialogOpen.mockReset();
    mocks.summary.mockReset();
    mocks.summary.mockReturnValue({
      scope: 'selected',
      memberInboxIds: [1, 2],
      mainInboxIds: [1],
      channels: [],
    });
  });

  it('shows one card per AI agent, active agents first, then by name', async () => {
    mocks.records = [...agents, helper];

    const wrapper = await mountPage();

    expect(cardNames(wrapper)).toEqual(['Арман', 'Мөлдір', 'Бота']);
    expect(wrapper.text()).not.toContain('Team helper');
  });

  it('loads the agents and the channel matrix for an administrator', async () => {
    await mountPage();

    expect(mocks.dispatch).toHaveBeenCalledWith('captainAssistants/get');
    expect(mocks.matrixFetch).toHaveBeenCalledTimes(1);
  });

  it('does not request the admin-only channel matrix for other users', async () => {
    mocks.isAdmin = false;

    await mountPage();

    expect(mocks.dispatch).toHaveBeenCalledWith('captainAssistants/get');
    expect(mocks.matrixFetch).not.toHaveBeenCalled();
  });

  it('shows the new agent tile and the create dialog only to administrators', async () => {
    mocks.records = agents;

    const adminPage = await mountPage();
    expect(adminPage.find('[data-testid="agent-new-tile"]').exists()).toBe(
      true
    );
    expect(
      adminPage.find('[data-testid="create-agent-dialog"]').exists()
    ).toBe(true);

    mocks.isAdmin = false;
    const agentPage = await mountPage();
    expect(agentPage.find('[data-testid="agent-new-tile"]').exists()).toBe(
      false
    );
    expect(
      agentPage.find('[data-testid="create-agent-dialog"]').exists()
    ).toBe(false);
    expect(
      agentPage
        .findAllComponents({ name: 'AgentGalleryCard' })
        .every(card => card.props('canToggle') === false)
    ).toBe(true);
  });

  it('shows only the new agent tile and one sentence when there are no agents', async () => {
    mocks.records = [helper];

    const wrapper = await mountPage();

    expect(cardNames(wrapper)).toEqual([]);
    expect(wrapper.find('[data-testid="agents-empty"]').text()).toBe(
      'CAPTAIN.GALLERY.EMPTY'
    );
    expect(wrapper.find('[data-testid="agent-new-tile"]').exists()).toBe(true);
  });

  it('shows only the sentence to a non-administrator without agents', async () => {
    mocks.isAdmin = false;

    const wrapper = await mountPage();

    expect(wrapper.find('[data-testid="agents-empty"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="agent-new-tile"]').exists()).toBe(false);
  });

  it('opens the create dialog from the new agent tile', async () => {
    const wrapper = await mountPage();

    await wrapper.find('[data-testid="agent-new-tile"]').trigger('click');

    expect(mocks.dialogOpen).toHaveBeenCalledTimes(1);
  });

  it('opens the agent page when a card is clicked', async () => {
    mocks.records = agents;
    const wrapper = await mountPage();

    wrapper.findAllComponents({ name: 'AgentGalleryCard' })[0].vm.$emit('open');

    expect(mocks.push).toHaveBeenCalledWith({
      name: 'captain_agent_show',
      params: { accountId: '1', assistantId: 9 },
    });
  });

  it('goes to the new agent page after it is created', async () => {
    const wrapper = await mountPage();

    wrapper
      .findComponent({ name: 'CreateAgentDialog' })
      .vm.$emit('created', { id: 42, name: 'Новый' });

    expect(mocks.push).toHaveBeenCalledWith({
      name: 'captain_agent_show',
      params: { accountId: '1', assistantId: 42 },
    });
    expect(mocks.matrixFetch).toHaveBeenLastCalledWith({ force: true });
  });

  it('builds the card status line from the channel summary', async () => {
    mocks.records = [agents[0]];
    mocks.matrix = { channels: [], assistants: [] };

    const wrapper = await mountPage();
    const card = wrapper.findComponent({ name: 'AgentGalleryCard' });

    expect(mocks.summary).toHaveBeenCalledWith({
      assistant: agents[0],
      matrix: mocks.matrix,
      inboxes: [],
    });
    expect(card.props('stats')).toEqual({
      scope: 'selected',
      mainCount: 1,
      memberCount: 2,
    });
  });

  it('leaves the channel count open for an «all channels» agent without the matrix', async () => {
    mocks.isAdmin = false;
    mocks.records = [agents[0]];
    mocks.summary.mockReturnValue({
      scope: 'all',
      memberInboxIds: [],
      mainInboxIds: [7],
      channels: [],
    });

    const wrapper = await mountPage();

    expect(
      wrapper.findComponent({ name: 'AgentGalleryCard' }).props('stats')
    ).toEqual({ scope: 'all', mainCount: 1, memberCount: null });
  });

  it('turns an agent off and refreshes the channel matrix after a save', async () => {
    mocks.records = agents;
    mocks.setActive.mockResolvedValue(true);
    const wrapper = await mountPage();
    mocks.matrixFetch.mockClear();

    wrapper
      .findAllComponents({ name: 'AgentGalleryCard' })[0]
      .vm.$emit('toggle-active', false);
    await flushPromises();

    expect(mocks.setActive).toHaveBeenCalledWith(
      expect.objectContaining({ id: 9 }),
      false
    );
    expect(mocks.matrixFetch).toHaveBeenCalledWith({ force: true });
  });

  it('keeps the matrix when the switch could not be saved', async () => {
    mocks.records = agents;
    mocks.setActive.mockResolvedValue(false);
    const wrapper = await mountPage();
    mocks.matrixFetch.mockClear();

    wrapper
      .findAllComponents({ name: 'AgentGalleryCard' })[0]
      .vm.$emit('toggle-active', false);
    await flushPromises();
    await nextTick();

    expect(mocks.matrixFetch).not.toHaveBeenCalled();
  });

  it('shows the paywall without loading anything', async () => {
    mocks.paywall = true;

    const wrapper = await mountPage();

    expect(wrapper.find('[data-testid="paywall"]').exists()).toBe(true);
    expect(mocks.dispatch).not.toHaveBeenCalled();
    expect(mocks.matrixFetch).not.toHaveBeenCalled();
  });
});
