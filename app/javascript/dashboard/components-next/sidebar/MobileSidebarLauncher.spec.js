import { reactive } from 'vue';
import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import MobileSidebarLauncher from './MobileSidebarLauncher.vue';

const route = reactive({
  name: 'communication_threads_dashboard',
  params: {},
});

vi.mock('vue-router', () => ({
  useRoute: () => route,
}));

describe('MobileSidebarLauncher', () => {
  it('shows the mobile menu launcher on conversation list routes', () => {
    route.name = 'communication_threads_dashboard';
    route.params = { accountId: '1' };

    const wrapper = shallowMount(MobileSidebarLauncher);
    expect(wrapper.find('#mobile-sidebar-launcher').exists()).toBe(true);
  });

  it.each([
    ['communication_thread_conversation', { communication_thread_id: '42' }],
    ['inbox_conversation', { conversation_id: '42' }],
    ['conversations_through_team', { conversationId: '42' }],
    ['inbox_view_conversation', { id: '42' }],
  ])(
    'hides the mobile menu launcher on %s so it does not overlap the reply box',
    (routeName, params) => {
      route.name = routeName;
      route.params = params;

      const wrapper = shallowMount(MobileSidebarLauncher);
      expect(wrapper.find('#mobile-sidebar-launcher').exists()).toBe(false);
    }
  );
});
