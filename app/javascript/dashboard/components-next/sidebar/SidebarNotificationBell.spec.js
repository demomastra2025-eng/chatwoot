import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SidebarNotificationBell from './SidebarNotificationBell.vue';

const { notificationMeta, routeState } = vi.hoisted(() => ({
  notificationMeta: { value: { unreadCount: 0 } },
  routeState: { name: 'dashboard' },
}));

vi.mock('vue-router', () => ({
  useRoute: () => routeState,
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => notificationMeta,
}));

const mountComponent = () => mount(SidebarNotificationBell);

describe('SidebarNotificationBell', () => {
  beforeEach(() => {
    notificationMeta.value = { unreadCount: 0 };
    routeState.name = 'dashboard';
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
    notificationMeta.value = { unreadCount: 120 };

    const wrapper = mountComponent();

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').text()).toBe(
      '99+'
    );
  });

  it('opens the notification panel outside the notifications page', async () => {
    const wrapper = mountComponent();

    await wrapper.trigger('click');

    expect(wrapper.emitted('openNotificationPanel')).toHaveLength(1);
  });

  it('does not reopen the notification panel from the notifications page', async () => {
    routeState.name = 'notifications_index';
    const wrapper = mountComponent();

    await wrapper.trigger('click');

    expect(wrapper.emitted('openNotificationPanel')).toBeUndefined();
  });
});
