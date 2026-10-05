import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

import assistantStore from 'dashboard/store/captain/assistant';

const mocks = vi.hoisted(() => ({
  records: [],
  dispatch: vi.fn(),
  push: vi.fn(),
  route: { name: 'captain_assistants_settings_index', params: {} },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
  useRouter: () => ({ push: mocks.push }),
}));

vi.mock('dashboard/composables/store.js', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key => {
    if (key === 'captainAssistants/getRecords') {
      // The real getter of the assistant store decides what the list shows.
      return computed(() =>
        assistantStore.getters.getRecords({ records: mocks.records })
      );
    }
    return computed(() => ({}));
  },
}));

vi.mock('dashboard/components-next/avatar/Avatar.vue', () => ({
  default: defineComponent({ name: 'Avatar', template: '<span />' }),
}));
vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    name: 'NextButton',
    emits: ['click'],
    setup(_, { slots, emit }) {
      return () =>
        h(
          'button',
          { 'data-testid': 'assistant-option', onClick: () => emit('click') },
          slots.default?.()
        );
    },
  }),
}));

const { default: AssistantSwitcher } = await import('./AssistantSwitcher.vue');

const agents = [
  { id: 3, name: 'Мөлдір', usage_mode: 'external_agent' },
  { id: 9, name: 'Арман', usage_mode: 'external_agent' },
];
const helper = { id: 5, name: 'Team helper', usage_mode: 'internal_assistant' };

describe('AssistantSwitcher', () => {
  beforeEach(() => {
    mocks.dispatch.mockReset();
    mocks.dispatch.mockResolvedValue({});
    mocks.push.mockReset();
    mocks.route = {
      name: 'captain_assistants_settings_index',
      params: { accountId: '1', assistantId: '3' },
    };
    mocks.records = [...agents, helper];
  });

  it('lists AI agents only: an internal assistant is not offered', () => {
    const wrapper = mount(AssistantSwitcher);
    const options = wrapper.findAll('[data-testid="assistant-option"]');

    expect(options.map(option => option.text())).toEqual(['Арман', 'Мөлдір']);
    expect(wrapper.text()).not.toContain('Team helper');
    expect(wrapper.text()).not.toContain('CAPTAIN.ASSISTANTS.INTERNAL_LABEL');
  });

  it('shows the empty list when the account only has an internal assistant', () => {
    mocks.records = [helper];

    const wrapper = mount(AssistantSwitcher);

    expect(wrapper.findAll('[data-testid="assistant-option"]')).toHaveLength(0);
    expect(wrapper.text()).toContain('CAPTAIN.ASSISTANT_SWITCHER.EMPTY_LIST');
    expect(wrapper.text()).not.toContain('Team helper');
  });

  it('switches to another AI agent on the same page', async () => {
    const wrapper = mount(AssistantSwitcher);

    await wrapper
      .findAll('[data-testid="assistant-option"]')[0]
      .trigger('click');
    await flushPromises();

    expect(mocks.push).toHaveBeenCalledWith({
      name: 'captain_assistants_settings_index',
      params: { accountId: '1', assistantId: 9 },
    });
    expect(wrapper.emitted('close')).toHaveLength(1);
  });
});
