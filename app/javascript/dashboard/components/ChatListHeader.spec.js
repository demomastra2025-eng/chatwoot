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
        ConversationStatusFilter: {
          props: ['modelValue', 'showAi'],
          emits: ['update:modelValue'],
          template:
            '<button data-test-id="status-filter" :data-show-ai="showAi" @click="$emit(\'update:modelValue\', \'resolved\')">{{ modelValue }}</button>',
        },
      },
    },
  });

describe('ChatListHeader', () => {
  it('renders the page title without the removed channel selector', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('h1').text()).toBe('Открытые диалоги');
    expect(wrapper.find('[data-test-id="channel-filter"]').exists()).toBe(
      false
    );
    expect(wrapper.text()).not.toContain(
      'CONVERSATION.COMMUNICATION_THREAD.ALL_CHANNELS'
    );
  });

  it('does not render a separate count badge when filters are applied', () => {
    const wrapper = mountComponent({ hasAppliedFilters: true });

    expect(wrapper.find('h1').text()).toBe('Открытые диалоги');
    expect(wrapper.find('.bg-n-slate-3').exists()).toBe(false);
  });

  it('renders the status selector next to the page title in status-filter mode', async () => {
    const wrapper = mountComponent({
      showStatusFilter: true,
      activeStatus: 'open',
      showAiStatus: true,
    });

    expect(wrapper.find('h1').text()).toBe('Открытые диалоги');
    const statusFilter = wrapper.find('[data-test-id="status-filter"]');
    expect(statusFilter.text()).toBe('open');
    expect(statusFilter.attributes('data-show-ai')).toBe('true');

    await statusFilter.trigger('click');
    expect(wrapper.emitted('statusFilterChange')).toEqual([['resolved']]);
  });

  it('keeps the title and the status selector when other list filters are applied', () => {
    const wrapper = mountComponent({
      showStatusFilter: true,
      hasAppliedFilters: true,
      activeStatus: 'all',
    });

    expect(wrapper.find('h1').text()).toBe('Открытые диалоги');
    expect(wrapper.find('[data-test-id="status-filter"]').text()).toBe('all');
  });

  it.each([
    ['a tag list', '#vip'],
    ['a team list', 'Sales team'],
    ['an inbox list', 'WhatsApp clinic'],
    ['the mentions list', 'Mentions'],
  ])(
    'still shows which list is open (%s) as the visible heading',
    (_, title) => {
      const wrapper = mountComponent({
        pageTitle: title,
        showStatusFilter: true,
        activeStatus: 'snoozed',
      });

      const heading = wrapper.get('h1');
      expect(heading.text()).toBe(title);
      expect(heading.isVisible()).toBe(true);
      expect(wrapper.find('[data-test-id="status-filter"]').exists()).toBe(
        true
      );
    }
  );
});
