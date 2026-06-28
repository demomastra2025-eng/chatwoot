import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import SidebarGroupLeaf from './SidebarGroupLeaf.vue';

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('./provider', () => ({
  useSidebarContext: () => ({
    resolvePermissions: () => [],
    resolveFeatureFlag: () => '',
  }),
}));

const mountComponent = (props = {}) =>
  mount(SidebarGroupLeaf, {
    props: {
      label: 'All',
      to: { name: 'communication_threads_dashboard' },
      icon: 'i-lucide-users-round',
      ...props,
    },
    global: {
      stubs: {
        Policy: {
          template: '<li v-bind="$attrs"><slot /></li>',
        },
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

describe('SidebarGroupLeaf', () => {
  it('renders conversation tab totals as plain text instead of unread badge styling', () => {
    const wrapper = mountComponent({ count: 42, badge: 42 });
    const count = wrapper.find('[data-test-id="sidebar-plain-count"]');

    expect(count.text()).toBe('42');
    expect(count.classes()).toContain('text-xs');
    expect(count.classes()).toContain('font-medium');
    expect(count.classes()).not.toContain('bg-n-brand/10');
    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').exists()).toBe(
      false
    );
  });

  it('keeps zero conversation totals visible as plain text', () => {
    const wrapper = mountComponent({ count: 0 });

    expect(wrapper.find('[data-test-id="sidebar-plain-count"]').text()).toBe(
      '0'
    );
  });

  it('shows large conversation totals without capping', () => {
    const wrapper = mountComponent({ count: 1234 });

    expect(wrapper.find('[data-test-id="sidebar-plain-count"]').text()).toBe(
      '1234'
    );
  });

  it('keeps the unread badge visual for unread badge counts', () => {
    const wrapper = mountComponent({ badge: 12 });
    const badge = wrapper.find('[data-test-id="sidebar-unread-badge"]');

    expect(wrapper.find('[data-test-id="sidebar-plain-count"]').exists()).toBe(
      false
    );
    expect(badge.text()).toBe('12');
    expect(badge.classes()).toContain('bg-n-brand/10');
  });

  it('renders CRM pipeline stage counts and a colored line before the title', () => {
    const wrapper = mountComponent({
      icon: null,
      count: 8,
      connectorColor: '#22C55E',
    });
    const link = wrapper.find('a');
    const accent = wrapper.find('[data-test-id="sidebar-stage-accent"]');

    expect(wrapper.find('[data-test-id="icon"]').exists()).toBe(false);
    expect(accent.exists()).toBe(true);
    expect(accent.classes()).toContain('h-4');
    expect(accent.attributes('style')).toContain(
      'background-color: rgb(34, 197, 94)'
    );
    expect(wrapper.find('[data-test-id="sidebar-plain-count"]').text()).toBe(
      '8'
    );
    expect(link.classes()).toContain('rounded-lg');
  });

  it('applies status color classes to appointment status label and count', () => {
    const wrapper = mountComponent({
      label: 'Подтвержден',
      icon: 'i-lucide-badge-check',
      iconClass: 'text-n-amber-11',
      labelClass: 'text-n-amber-11',
      count: 7,
      countClass: 'text-n-amber-11',
    });
    const count = wrapper.find('[data-test-id="sidebar-plain-count"]');

    expect(wrapper.text()).toContain('Подтвержден');
    expect(count.text()).toBe('7');
    expect(count.classes()).toContain('text-n-amber-11');
    expect(
      wrapper
        .findAll('.text-n-amber-11')
        .some(element => element.text().includes('Подтвержден'))
    ).toBe(true);
  });
});
