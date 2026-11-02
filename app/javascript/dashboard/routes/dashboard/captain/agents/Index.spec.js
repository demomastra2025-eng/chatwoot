/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

import assistantStore from 'dashboard/store/captain/assistant';

const mocks = vi.hoisted(() => ({
  records: [],
  inboxes: [],
  isAdmin: true,
  currentUser: { type: 'SuperAdmin', captain_platform_access: true },
  paywall: false,
  push: vi.fn(),
  dispatch: vi.fn(),
  setActive: vi.fn(),
  dialogOpen: vi.fn(),
  switchOffOpen: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key} ${JSON.stringify(params)}` : key),
    te: () => true,
  }),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: mocks.push }),
  useRoute: () => ({ params: { accountId: '1' } }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key => {
    if (key === 'getCurrentUser') return computed(() => mocks.currentUser);
    if (key === 'captainAssistants/getRecords') {
      // The real getter of the assistant store decides who is listed.
      return computed(() =>
        assistantStore.getters.getRecords({ records: mocks.records })
      );
    }
    if (key === 'inboxes/getInboxes') return computed(() => mocks.inboxes);
    return computed(() => ({ fetchingList: false }));
  },
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: () => mocks.isAdmin,
    shouldShowPaywall: () => mocks.paywall,
  }),
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

// The tests emit the card and dialog events themselves, so the card stub and
// the dialog stubs below declare no events of their own.
vi.mock('dashboard/components-next/captain/agent/AgentGalleryCard.vue', () => ({
  default: defineComponent({
    name: 'AgentGalleryCard',
    props: {
      assistant: { type: Object, required: true },
      canToggle: Boolean,
      toggling: Boolean,
      enabledCount: { type: Number, default: 0 },
    },
    setup(props) {
      return () =>
        h(
          'div',
          {
            'data-testid': 'agent-card',
            'data-can-toggle': props.canToggle,
            'data-toggling': props.toggling,
            'data-enabled-count': props.enabledCount,
          },
          props.assistant.name
        );
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
      setup(_props, { expose }) {
        expose({ dialogRef: { open: mocks.dialogOpen } });
        return () => h('div', { 'data-testid': 'create-agent-dialog' });
      },
    }),
  })
);

vi.mock(
  'dashboard/components-next/captain/agent/AgentSwitchOffDialog.vue',
  () => ({
    default: defineComponent({
      name: 'AgentSwitchOffDialog',
      props: { description: { type: String, default: '' } },
      setup(props, { expose }) {
        expose({ open: mocks.switchOffOpen });
        return () =>
          h('div', { 'data-testid': 'switch-off-dialog' }, props.description);
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

const cards = wrapper =>
  wrapper.findAllComponents({ name: 'AgentGalleryCard' });

const agents = [
  { id: 3, name: 'Мөлдір', usage_mode: 'external_agent', active: true },
  { id: 9, name: 'Арман', usage_mode: 'external_agent', active: true },
  { id: 4, name: 'Бота', usage_mode: 'external_agent', active: false },
];
const helper = { id: 5, name: 'Team helper', usage_mode: 'internal_assistant' };

describe('Captain agents gallery', () => {
  beforeEach(() => {
    mocks.records = [];
    mocks.inboxes = [];
    mocks.isAdmin = true;
    mocks.currentUser = { type: 'SuperAdmin', captain_platform_access: true };
    mocks.paywall = false;
    mocks.push.mockReset();
    mocks.dispatch.mockReset();
    mocks.dispatch.mockResolvedValue([]);
    mocks.setActive.mockReset();
    mocks.setActive.mockResolvedValue(true);
    mocks.dialogOpen.mockReset();
    mocks.switchOffOpen.mockReset();
  });

  it('shows one card per AI agent, active agents first, then by name', async () => {
    mocks.records = [...agents, helper];

    const wrapper = await mountPage();

    expect(cardNames(wrapper)).toEqual(['Арман', 'Мөлдір', 'Бота']);
    expect(wrapper.text()).not.toContain('Team helper');
  });

  it('loads the agents only: the gallery needs no channel matrix', async () => {
    await mountPage();

    expect(mocks.dispatch).toHaveBeenCalledTimes(1);
    expect(mocks.dispatch).toHaveBeenCalledWith('captainAssistants/get');
  });

  it('tells every card how many agents are on', async () => {
    mocks.records = agents;

    const wrapper = await mountPage();

    expect(cards(wrapper).every(card => card.props('enabledCount') === 2)).toBe(
      true
    );
  });

  it('shows the new agent tile and the create dialog only to administrators', async () => {
    mocks.records = agents;

    const adminPage = await mountPage();
    expect(adminPage.find('[data-testid="agent-new-tile"]').exists()).toBe(
      true
    );
    expect(adminPage.find('[data-testid="create-agent-dialog"]').exists()).toBe(
      true
    );

    mocks.isAdmin = false;
    const agentPage = await mountPage();
    expect(agentPage.find('[data-testid="agent-new-tile"]').exists()).toBe(
      false
    );
    expect(agentPage.find('[data-testid="create-agent-dialog"]').exists()).toBe(
      false
    );
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

  it.each(['administrator', 'agent'])(
    'has no creation actions for an ordinary %s, including empty lists',
    async role => {
      mocks.isAdmin = role === 'administrator';
      mocks.currentUser = { type: 'User', captain_platform_access: false };
      const wrapper = await mountPage();
      expect(wrapper.find('[data-testid="agents-empty"]').exists()).toBe(true);
      expect(wrapper.find('[data-testid="agent-new-tile"]').exists()).toBe(
        false
      );
      expect(wrapper.find('[data-testid="create-agent-dialog"]').exists()).toBe(
        false
      );
    }
  );

  it('opens the create dialog from the new agent tile', async () => {
    const wrapper = await mountPage();

    await wrapper.find('[data-testid="agent-new-tile"]').trigger('click');

    expect(mocks.dialogOpen).toHaveBeenCalledTimes(1);
  });

  it('opens the agent page when a card is clicked', async () => {
    mocks.records = agents;
    const wrapper = await mountPage();

    cards(wrapper)[0].vm.$emit('open');

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
  });

  describe('the on/off switch', () => {
    it('turns an agent off at once when others stay on', async () => {
      mocks.records = agents;
      const wrapper = await mountPage();

      cards(wrapper)[0].vm.$emit('toggleActive', false);
      await flushPromises();

      expect(mocks.setActive).toHaveBeenCalledWith(
        expect.objectContaining({ id: 9 }),
        false
      );
      expect(mocks.switchOffOpen).not.toHaveBeenCalled();
    });

    it('turns an agent on at once', async () => {
      mocks.records = agents;
      const wrapper = await mountPage();

      cards(wrapper)[2].vm.$emit('toggleActive', true);
      await flushPromises();

      expect(mocks.setActive).toHaveBeenCalledWith(
        expect.objectContaining({ id: 4 }),
        true
      );
      expect(mocks.switchOffOpen).not.toHaveBeenCalled();
    });

    it('lets the former default agent be switched off like any other', async () => {
      mocks.records = [
        { id: 1, name: 'Диана', usage_mode: 'external_agent', active: true },
        ...agents,
      ];
      const wrapper = await mountPage();

      const diana = cards(wrapper).find(
        card => card.props('assistant').id === 1
      );
      diana.vm.$emit('toggleActive', false);
      await flushPromises();

      expect(mocks.setActive).toHaveBeenCalledWith(
        expect.objectContaining({ id: 1 }),
        false
      );
    });

    it('asks first before the last enabled agent is switched off, and switches it off on confirm', async () => {
      mocks.records = [agents[0], agents[2]];
      const wrapper = await mountPage();

      cards(wrapper)[0].vm.$emit('toggleActive', false);
      await flushPromises();

      expect(mocks.setActive).not.toHaveBeenCalled();
      expect(mocks.switchOffOpen).toHaveBeenCalledTimes(1);
      expect(
        wrapper.find('[data-testid="switch-off-dialog"]').text()
      ).toContain('CAPTAIN.GALLERY.CONFIRM_DISABLE_LAST');

      wrapper
        .findComponent({ name: 'AgentSwitchOffDialog' })
        .vm.$emit('confirm');
      await flushPromises();

      expect(mocks.setActive).toHaveBeenCalledWith(
        expect.objectContaining({ id: 3 }),
        false
      );
    });

    it('asks first before an agent that answers a phone number is switched off', async () => {
      mocks.records = [{ ...agents[0], voice_inbox_ids: [11] }, agents[1]];
      mocks.inboxes = [
        {
          id: 11,
          channel_type: 'Channel::Voice',
          name: 'Calls',
          phone_number: '+77010000000',
        },
      ];
      const wrapper = await mountPage();

      const voiceCard = cards(wrapper).find(
        card => card.props('assistant').id === 3
      );
      voiceCard.vm.$emit('toggleActive', false);
      await flushPromises();

      expect(mocks.setActive).not.toHaveBeenCalled();
      expect(
        wrapper.find('[data-testid="switch-off-dialog"]').text()
      ).toContain(
        'CAPTAIN.GALLERY.CONFIRM_DISABLE_VOICE {"numbers":"+77010000000"}'
      );
    });
  });

  describe('the switch for all agents', () => {
    it('asks before it switches off every agent, then switches off the ones that are on', async () => {
      mocks.records = agents;
      const wrapper = await mountPage();

      await wrapper.find('[data-testid="agents-toggle-all"]').trigger('click');
      await flushPromises();

      expect(mocks.setActive).not.toHaveBeenCalled();
      expect(wrapper.find('[data-testid="switch-off-dialog"]').text()).toBe(
        'CAPTAIN.GALLERY.CONFIRM_DISABLE_ALL'
      );

      wrapper
        .findComponent({ name: 'AgentSwitchOffDialog' })
        .vm.$emit('confirm');
      await flushPromises();

      expect(
        mocks.setActive.mock.calls.map(([agent, active]) => [agent.id, active])
      ).toEqual([
        [9, false],
        [3, false],
      ]);
    });

    it('switches every agent on, with no question, when none is on', async () => {
      mocks.records = agents.map(agent => ({ ...agent, active: false }));
      const wrapper = await mountPage();

      expect(wrapper.find('[data-testid="agents-toggle-all"]').text()).toBe(
        'CAPTAIN.GALLERY.ENABLE_ALL_AGENTS'
      );
      await wrapper.find('[data-testid="agents-toggle-all"]').trigger('click');
      await flushPromises();

      expect(mocks.switchOffOpen).not.toHaveBeenCalled();
      expect(mocks.setActive).toHaveBeenCalledTimes(3);
      expect(
        mocks.setActive.mock.calls.every(([, active]) => active === true)
      ).toBe(true);
    });

    it('is offered to administrators only', async () => {
      mocks.records = agents;
      mocks.isAdmin = false;

      const wrapper = await mountPage();

      expect(wrapper.find('[data-testid="agents-toggle-all"]').exists()).toBe(
        false
      );
    });
  });

  it('shows the paywall without loading anything', async () => {
    mocks.paywall = true;

    const wrapper = await mountPage();

    expect(wrapper.find('[data-testid="paywall"]').exists()).toBe(true);
    expect(mocks.dispatch).not.toHaveBeenCalled();
  });
});
