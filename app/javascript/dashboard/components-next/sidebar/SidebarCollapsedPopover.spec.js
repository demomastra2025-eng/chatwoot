import { mount } from '@vue/test-utils';
import { describe, expect, it, beforeEach, vi } from 'vitest';

import SidebarCollapsedPopover from './SidebarCollapsedPopover.vue';

const { routerPush } = vi.hoisted(() => ({
  routerPush: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: routerPush }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({ value: false }),
}));

vi.mock('./provider', () => ({
  useSidebarContext: () => ({
    isAllowed: () => true,
    sidebarWidth: { value: 56 },
  }),
}));

const labelsSettingsRoute = {
  name: 'labels_list',
  params: { accountId: 1 },
};

const mountComponent = () =>
  mount(SidebarCollapsedPopover, {
    props: {
      label: 'Conversations',
      triggerRect: { top: 20, left: 0, bottom: 60, right: 40 },
      children: [
        {
          name: 'Labels',
          label: 'Tags',
          icon: 'i-lucide-tag',
          badge: 123,
          to: { name: 'home' },
          actionItems: [
            {
              title: 'Tag settings',
              icon: 'i-lucide-settings-2',
              to: labelsSettingsRoute,
            },
          ],
          children: [
            {
              name: 'all-labels',
              label: 'All tags',
              to: { name: 'home' },
            },
          ],
        },
      ],
    },
    global: {
      stubs: {
        Icon: {
          props: ['icon'],
          template: '<span data-test-id="icon" :data-icon="icon" />',
        },
        TeleportWithDirection: {
          template: '<div><slot /></div>',
        },
      },
    },
  });

describe('SidebarCollapsedPopover', () => {
  beforeEach(() => {
    routerPush.mockClear();
  });

  it('opens subgroup action item routes from the collapsed sidebar popover', async () => {
    const wrapper = mountComponent();
    const settingsButton = wrapper.find('button[title="Tag settings"]');

    expect(settingsButton.exists()).toBe(true);

    await settingsButton.trigger('click');

    expect(routerPush).toHaveBeenCalledWith(labelsSettingsRoute);
    expect(wrapper.emitted('close')).toBeTruthy();
  });

  it('renders unread badges in the collapsed sidebar popover', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').text()).toBe(
      '99+'
    );
  });
});
