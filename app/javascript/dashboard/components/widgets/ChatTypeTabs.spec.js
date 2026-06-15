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
          props: ['index', 'name', 'count', 'showBadge'],
          template:
            '<div data-test-id="tab-item" :data-name="name" :data-count="count" :data-show-badge="showBadge"><slot :tab-name="name" :count="count" :active="index === 0">{{ name }}</slot></div>',
        },
      },
    },
  });

describe('ChatTypeTabs', () => {
  it('shows assignee tab totals inline and disables badge styling', () => {
    const wrapper = mountComponent();

    const tabItems = wrapper.findAll('[data-test-id="tab-item"]');

    expect(tabItems[0].attributes('data-name')).toBe('Мои');
    expect(tabItems[0].attributes('data-count')).toBe('42');
    expect(tabItems[0].attributes('data-show-badge')).toBe('false');
    expect(tabItems[0].text()).toBe('Мои 42');
    expect(tabItems[0].text()).not.toContain('(42)');
    expect(tabItems[0].text()).not.toContain('7');

    const counters = wrapper.findAll('[data-test-id="tab-counter"]');
    expect(counters[0].classes()).toContain('ltr:ml-0.5');
    expect(counters[0].classes()).toContain('text-n-blue-11');
    expect(counters[0].classes()).not.toContain('text-n-slate-9');
    expect(counters[0].classes()).not.toContain('text-n-slate-12');
    expect(counters[0].text()).toBe('42');
    expect(counters[1].classes()).toContain('text-n-slate-9');

    expect(tabItems[1].attributes('data-name')).toBe('Все');
    expect(tabItems[1].attributes('data-count')).toBe('99');
    expect(tabItems[1].attributes('data-show-badge')).toBe('false');
  });
});
