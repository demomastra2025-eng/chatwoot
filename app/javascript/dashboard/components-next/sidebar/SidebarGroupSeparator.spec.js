import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import SidebarGroupSeparator from './SidebarGroupSeparator.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({ name: 'communication_threads_dashboard', path: '/' }),
  useRouter: () => ({
    push: vi.fn(),
    resolve: to => ({ path: to?.path || '/' }),
  }),
}));

const mountComponent = props =>
  mount(SidebarGroupSeparator, {
    props: {
      label: 'Pipeline',
      icon: 'i-lucide-filter',
      ...props,
    },
    global: {
      stubs: {
        Icon: {
          props: ['icon'],
          template: '<span data-test-id="icon" :data-icon="icon" />',
        },
        RouterLink: {
          props: ['to'],
          template: '<a><slot /></a>',
        },
      },
    },
  });

describe('SidebarGroupSeparator', () => {
  it('renders CRM pipeline totals as plain text instead of unread badge styling', () => {
    const wrapper = mountComponent({ count: 12, badge: 12 });
    const count = wrapper.find('[data-test-id="sidebar-plain-count"]');

    expect(count.text()).toBe('12');
    expect(count.classes()).toContain('text-xs');
    expect(count.classes()).toContain('font-medium');
    expect(count.classes()).toContain('px-1');
    expect(count.classes()).not.toContain('bg-n-brand/10');
    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').exists()).toBe(
      false
    );
  });

  it('keeps unread badge styling when only badge is provided', () => {
    const wrapper = mountComponent({ badge: 12 });
    const badge = wrapper.find('[data-test-id="sidebar-unread-badge"]');

    expect(wrapper.find('[data-test-id="sidebar-plain-count"]').exists()).toBe(
      false
    );
    expect(badge.text()).toBe('12');
    expect(badge.classes()).toContain('bg-n-brand/10');
  });
});
