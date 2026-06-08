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
      conversationStats: { allCount: 12 },
      isListLoading: false,
      showChannelFilter: false,
      channelFilterItems: [],
      activeChannelFilterKey: '',
      ...props,
    },
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        ConversationBasicFilter: true,
        ConversationLocalSearch: true,
        SwitchLayout: true,
        NextButton: true,
        ChatListChannelFilter: {
          props: ['items', 'activeKey'],
          emits: ['select'],
          template:
            '<button data-test-id="channel-filter" @click="$emit(\'select\', items[0])">{{ items[0]?.label }}</button>',
        },
      },
    },
  });

describe('ChatListHeader', () => {
  it('replaces the old page title with channel selector in channel-filter mode', async () => {
    const wrapper = mountComponent({
      showChannelFilter: true,
      channelFilterItems: [{ key: 'all', label: 'Все каналы' }],
      activeChannelFilterKey: 'all',
    });

    expect(wrapper.find('h1').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('Открытые диалоги');
    expect(wrapper.find('[data-test-id="channel-filter"]').text()).toContain(
      'Все каналы'
    );

    await wrapper.find('[data-test-id="channel-filter"]').trigger('click');
    expect(wrapper.emitted('channelFilterSelect')).toEqual([
      [{ key: 'all', label: 'Все каналы' }],
    ]);
  });

  it('keeps channel selector in place when other list filters are applied', () => {
    const wrapper = mountComponent({
      showChannelFilter: true,
      hasAppliedFilters: true,
      channelFilterItems: [{ key: 'all', label: 'Все каналы' }],
      activeChannelFilterKey: 'all',
    });

    expect(wrapper.find('h1').exists()).toBe(false);
    expect(wrapper.find('[data-test-id="channel-filter"]').text()).toContain(
      'Все каналы'
    );
  });

  it('keeps the normal title outside channel-filter mode', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('h1').text()).toBe('Открытые диалоги');
  });
});
