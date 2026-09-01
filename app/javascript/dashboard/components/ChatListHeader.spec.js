import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

import ChatListHeader from './ChatListHeader.vue';

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: ref({}),
    updateUISettings: vi.fn(),
  }),
}));

const mountComponent = props =>
  mount(ChatListHeader, {
    props: {
      pageTitle: 'Открытые диалоги',
      hasAppliedFilters: false,
      hasActiveFolders: false,
      isOnExpandedLayout: false,
      showStatusFilter: false,
      ...props,
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        ConversationBasicFilter: true,
        ConversationLocalSearch: true,
        SwitchLayout: true,
        NextButton: true,
        ConversationStatusFilter: {
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template:
            '<button data-test-id="status-filter" @click="$emit(\'update:modelValue\', \'resolved\')">{{ modelValue }}</button>',
        },
      },
    },
  });

describe('ChatListHeader', () => {
  it('renders the status selector instead of All channels', async () => {
    const wrapper = mountComponent({
      showStatusFilter: true,
      activeStatus: 'open',
    });

    expect(wrapper.find('h1').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('Открытые диалоги');
    expect(wrapper.text()).not.toContain('Все каналы');
    expect(wrapper.find('[data-test-id="status-filter"]').text()).toBe('open');

    await wrapper.find('[data-test-id="status-filter"]').trigger('click');
    expect(wrapper.emitted('statusFilterChange')).toEqual([['resolved']]);
  });

  it('keeps the status selector in place when other list filters are applied', () => {
    const wrapper = mountComponent({
      showStatusFilter: true,
      hasAppliedFilters: true,
      activeStatus: 'open',
    });

    expect(wrapper.find('h1').exists()).toBe(false);
    expect(wrapper.find('[data-test-id="status-filter"]').text()).toBe('open');
  });

  it('keeps the normal title outside status-filter mode', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('h1').text()).toBe('Открытые диалоги');
  });
});
