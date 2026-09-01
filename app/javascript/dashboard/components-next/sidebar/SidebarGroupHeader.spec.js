import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SidebarGroupHeader from './SidebarGroupHeader.vue';

const { dynamicCount, showBadge } = vi.hoisted(() => ({
  dynamicCount: { value: 0 },
  showBadge: { value: false },
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('dashboard/composables/store.js', () => ({
  useMapGetter: getter => {
    const getters = {
      unreadCount: dynamicCount,
      hasUnread: showBadge,
    };

    return getters[getter] || { value: false };
  },
}));

vi.mock('next/icon/Icon.vue', () => ({
  default: {
    name: 'Icon',
    props: ['icon'],
    template: '<span data-test-id="icon" :data-icon="icon" />',
  },
}));

const mountComponent = (props = {}) =>
  mount(SidebarGroupHeader, {
    props: {
      label: 'Tags',
      icon: 'i-lucide-tag',
      getterKeys: {
        count: 'unreadCount',
        badge: 'hasUnread',
      },
      ...props,
    },
    global: {
      stubs: {
        RouterLink: {
          props: ['to'],
          template: '<a><slot /></a>',
        },
      },
    },
  });

describe('SidebarGroupHeader', () => {
  beforeEach(() => {
    dynamicCount.value = 0;
    showBadge.value = false;
  });

  it('highlights the main icon item when one of its children is active', () => {
    const wrapper = mountComponent({ hasActiveChild: true });
    const item = wrapper.find('[title="Tags"]');

    expect(item.classes()).toContain('bg-n-brand-solid');
    expect(item.classes()).toContain('text-n-brand-contrast');
  });

  it('shows three-digit counts without capping', () => {
    dynamicCount.value = 120;

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('120');
  });

  it('does not cap the boundary count', () => {
    dynamicCount.value = 999;

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('999');
    expect(wrapper.text()).not.toContain('999+');
  });

  it('caps large counts at 999+', () => {
    dynamicCount.value = 1200;

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('999+');
  });

  it('renders multiple header actions and calls action handlers', async () => {
    const openCompose = vi.fn();
    const wrapper = mountComponent({
      actions: [
        {
          key: 'settings',
          label: 'Settings',
          icon: 'i-lucide-settings-2',
          to: { name: 'settings' },
        },
        {
          key: 'compose',
          label: 'New message',
          icon: 'i-lucide-plus',
          handler: openCompose,
        },
      ],
    });

    const actionButtons = wrapper.findAll('button');

    expect(actionButtons).toHaveLength(2);
    expect(actionButtons[0].attributes('title')).toBe('Settings');
    expect(actionButtons[1].attributes('title')).toBe('New message');

    await actionButtons[1].trigger('click');

    expect(openCompose).toHaveBeenCalledTimes(1);
  });
});
