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

const mountComponent = () =>
  mount(SidebarGroupHeader, {
    props: {
      label: 'Tags',
      icon: 'i-lucide-tag',
      getterKeys: {
        count: 'unreadCount',
        badge: 'hasUnread',
      },
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
});
