import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ChatTypeTabs from './ChatTypeTabs.vue';

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

const mountComponent = props =>
  mount(ChatTypeTabs, {
    props: {
      items: [
        {
          key: 'me',
          name: 'Мои',
          totalCount: 42,
          count: 7,
          unreadMessageCount: 128,
        },
        {
          key: 'all',
          name: 'Все',
          totalCount: 99,
          count: 12,
          unreadMessageCount: 256,
        },
      ],
      activeTab: 'me',
      ...props,
    },
    global: {
      stubs: {
        WootTabs: {
          props: ['index'],
          emits: ['change'],
          template: '<div data-test-id="tabs"><slot /></div>',
        },
        WootTabsItem: {
          props: ['index', 'name', 'count'],
          template:
            '<div data-test-id="tab-item" :data-name="name" :data-count="count">{{ name }}:{{ count }}</div>',
        },
      },
    },
  });

describe('ChatTypeTabs', () => {
  it('shows the blue tab counter from unread dialog/thread totals, not message totals', () => {
    const wrapper = mountComponent();

    const tabItems = wrapper.findAll('[data-test-id="tab-item"]');

    expect(tabItems[0].attributes('data-name')).toBe('Мои');
    expect(tabItems[0].attributes('data-count')).toBe('7');
    expect(tabItems[0].text()).not.toContain(':42');
    expect(tabItems[0].text()).not.toContain(':128');
    expect(tabItems[1].attributes('data-count')).toBe('12');
  });
});
