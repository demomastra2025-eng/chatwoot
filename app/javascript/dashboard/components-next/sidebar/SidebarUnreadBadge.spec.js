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

  it('caps large counts at 99+', () => {
    const wrapper = mount(SidebarUnreadBadge, {
      props: { value: 120 },
    });

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').text()).toBe(
      '99+'
    );
  });
});
