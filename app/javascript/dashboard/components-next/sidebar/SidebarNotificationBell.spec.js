import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SidebarNotificationBell from './SidebarNotificationBell.vue';

const { notificationMeta } = vi.hoisted(() => ({
  notificationMeta: { value: { unreadCount: 0 } },
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => notificationMeta,
}));

const mountComponent = (props = {}) =>
  mount(SidebarNotificationBell, { props });

describe('SidebarNotificationBell', () => {
  beforeEach(() => {
    notificationMeta.value = { unreadCount: 0 };
  });

  it('uses the shared sidebar unread badge visual for notification counts', () => {
    notificationMeta.value = { unreadCount: 12 };

    const wrapper = mountComponent();
    const badge = wrapper.find('[data-test-id="sidebar-unread-badge"]');

    expect(badge.text()).toBe('12');
    expect(badge.attributes('class')).toContain('bg-n-brand/10');
    expect(badge.attributes('class')).toContain('text-n-brand');
    expect(badge.attributes('class')).not.toContain('bg-n-ruby-9');
  });

  it('caps large notification counts through the shared badge', () => {
    notificationMeta.value = { unreadCount: 1200 };

    const wrapper = mountComponent();

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').text()).toBe(
      '999+'
    );
  });

  it('always opens the notification panel instead of navigating', async () => {
    const wrapper = mountComponent();

    await wrapper.get('button').trigger('click');

    expect(wrapper.emitted('openNotificationPanel')).toHaveLength(1);
  });

  it('shows the label in expanded sidebar mode', () => {
    const wrapper = mountComponent({
      isCollapsed: false,
      label: 'Notifications',
    });

    expect(wrapper.text()).toContain('Notifications');
    expect(wrapper.get('button').classes()).toContain('w-full');
  });
});
