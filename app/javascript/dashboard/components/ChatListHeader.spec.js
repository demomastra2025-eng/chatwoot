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

  it('renders the status selector instead of the title in status-filter mode', async () => {
    const wrapper = mountComponent({
      showStatusFilter: true,
      activeStatus: 'open',
      showAiStatus: true,
    });

    expect(wrapper.find('h1').exists()).toBe(false);
    const statusFilter = wrapper.find('[data-test-id="status-filter"]');
    expect(statusFilter.text()).toBe('open');
    expect(statusFilter.attributes('data-show-ai')).toBe('true');

    await statusFilter.trigger('click');
    expect(wrapper.emitted('statusFilterChange')).toEqual([['resolved']]);
  });

  it('keeps the status selector in place when other list filters are applied', () => {
    const wrapper = mountComponent({
      showStatusFilter: true,
      hasAppliedFilters: true,
      activeStatus: 'all',
    });

    expect(wrapper.find('h1').exists()).toBe(false);
    expect(wrapper.find('[data-test-id="status-filter"]').text()).toBe('all');
  });

  // 666f7bd5d asserted that tag, team, inbox and mention lists keep a
  // visible h1. The status selector now replaces it everywhere (aset/dev),
  // so the same lists assert the selector heading and the list name tooltip.
  it.each([
    ['a tag list', '#vip'],
    ['a team list', 'Sales team'],
    ['an inbox list', 'WhatsApp clinic'],
    ['the mentions list', 'Mentions'],
  ])(
    'shows the status selector as the heading of %s and keeps its name as the tooltip',
    (_, title) => {
      const wrapper = mountComponent({
        pageTitle: title,
        showStatusFilter: true,
        activeStatus: 'snoozed',
      });

      expect(wrapper.find('h1').exists()).toBe(false);
      const statusFilter = wrapper.get('[data-test-id="status-filter"]');
      expect(statusFilter.text()).toBe('snoozed');
      expect(statusFilter.attributes('title')).toBe(title);
    }
  );

  it('keeps the pending (AI) status visible without Captain', () => {
    const wrapper = mountComponent({
      showStatusFilter: true,
      activeStatus: 'pending',
      showAiStatus: false,
    });

    const statusFilter = wrapper.get('[data-test-id="status-filter"]');
    expect(statusFilter.text()).toBe('pending');
    expect(statusFilter.attributes('data-show-ai')).toBe('false');
  });

  it('shows the title without a selector in a saved folder', () => {
    const wrapper = mountComponent({
      pageTitle: 'Мои VIP',
      hasActiveFolders: true,
      showStatusFilter: false,
    });

    expect(wrapper.get('h1').text()).toBe('Мои VIP');
    expect(wrapper.find('[data-test-id="status-filter"]').exists()).toBe(false);
  });
});
