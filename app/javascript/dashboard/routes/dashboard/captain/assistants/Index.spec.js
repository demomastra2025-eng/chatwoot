import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';

import assistantStore from 'dashboard/store/captain/assistant';

const mocks = vi.hoisted(() => ({
  records: [],
  push: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({
    push: mocks.push,
    currentRoute: { value: { params: { accountId: '1' } } },
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key => {
    if (key === 'captainAssistants/getRecords') {
      // The real getter of the assistant store decides what the list shows.
      return computed(() =>
        assistantStore.getters.getRecords({ records: mocks.records })
      );
    }
    return computed(() => ({ fetchingList: false }));
  },
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ isOnChatwootCloud: false }),
}));

// Mirrors PageLayout: the empty state replaces the body of an empty list.
vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    props: { isEmpty: { type: Boolean, default: false } },
    setup(props, { slots }) {
      return () =>
        h('div', [
          props.isEmpty ? slots.emptyState?.() : slots.body?.(),
          slots.default?.(),
        ]);
    },
  }),
}));
vi.mock(
  'dashboard/components-next/captain/assistant/AssistantCard.vue',
  () => ({
    default: defineComponent({
      name: 'AssistantCard',
      props: ['name'],
      setup(props) {
        return () => h('div', { 'data-testid': 'assistant-card' }, props.name);
      },
    }),
  })
);
vi.mock(
  'dashboard/components-next/captain/pageComponents/emptyStates/AssistantPageEmptyState.vue',
  () => ({
    default: defineComponent({
      name: 'AssistantPageEmptyState',
      template: '<div data-testid="empty-state" />',
    }),
  })
);
vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/CreateAssistantDialog.vue',
  () => ({
    default: defineComponent({
      name: 'CreateAssistantDialog',
      template: '<div />',
    }),
  })
);
vi.mock('dashboard/components-next/captain/pageComponents/Paywall.vue', () => ({
  default: defineComponent({ name: 'CaptainPaywall', template: '<div />' }),
}));
vi.mock(
  'dashboard/components-next/feature-spotlight/FeatureSpotlightPopover.vue',
  () => ({
    default: defineComponent({
      name: 'FeatureSpotlightPopover',
      template: '<div />',
    }),
  })
);

const { default: AssistantsIndex } = await import('./Index.vue');

const mountPage = () =>
  mount(AssistantsIndex, {
    global: { mocks: { $t: key => key } },
  });

const now = 1700000000;
const agents = [
  { id: 3, name: 'Мөлдір', usage_mode: 'external_agent', updated_at: now },
  { id: 9, name: 'Арман', usage_mode: 'external_agent', updated_at: now },
];
const helper = {
  id: 5,
  name: 'Team helper',
  usage_mode: 'internal_assistant',
  updated_at: now,
};

describe('Captain assistants list page', () => {
  beforeEach(() => {
    mocks.push.mockReset();
    mocks.records = [];
  });

  it('shows a card for every AI agent', () => {
    mocks.records = agents;

    const cards = mountPage().findAll('[data-testid="assistant-card"]');

    expect(cards.map(card => card.text())).toEqual(['Арман', 'Мөлдір']);
  });

  it('hides the internal assistants from the list', () => {
    mocks.records = [...agents, helper];

    const wrapper = mountPage();

    expect(wrapper.findAll('[data-testid="assistant-card"]')).toHaveLength(2);
    expect(wrapper.text()).not.toContain('Team helper');
  });

  it('shows the empty state to create the first agent when only an internal assistant exists', () => {
    mocks.records = [helper];

    const wrapper = mountPage();

    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true);
    expect(wrapper.findAll('[data-testid="assistant-card"]')).toHaveLength(0);
  });

  it('shows the empty state for an account without any assistant', () => {
    const wrapper = mountPage();

    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true);
  });
});
