import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import SidebarUnreadBadge from './SidebarUnreadBadge.vue';

describe('SidebarUnreadBadge', () => {
  it('hides zero values', () => {
    const wrapper = mount(SidebarUnreadBadge, {
      props: { value: 0 },
    });

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').exists()).toBe(
      false
    );
  });

  it('shows three-digit counts without capping', () => {
    const wrapper = mount(SidebarUnreadBadge, {
      props: { value: 120 },
    });

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').text()).toBe(
      '120'
    );
  });

  it('does not cap the boundary count', () => {
    const wrapper = mount(SidebarUnreadBadge, {
      props: { value: 999 },
    });

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').text()).toBe(
      '999'
    );
  });

  it('caps large counts at 999+', () => {
    const wrapper = mount(SidebarUnreadBadge, {
      props: { value: 1200 },
    });

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').text()).toBe(
      '999+'
    );
  });

  it('forwards positioning classes to the visible badge element', () => {
    const wrapper = mount(SidebarUnreadBadge, {
      props: { value: 3 },
      attrs: { class: 'absolute -top-1' },
    });

    const badge = wrapper.find('[data-test-id="sidebar-unread-badge"]');

    expect(badge.classes()).toContain('absolute');
    expect(badge.classes()).toContain('-top-1');
  });
});
