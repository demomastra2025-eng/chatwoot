import { mount } from '@vue/test-utils';
import { describe, expect, it, beforeEach, vi } from 'vitest';
import { nextTick } from 'vue';

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

const allLabelsRoute = { name: 'home' };
const allChannelsRoute = { name: 'home', query: { status: 'open' } };

const defaultChildren = [
  {
    name: 'Labels',
    label: 'Tags',
    icon: 'i-lucide-tag',
    badge: 1234,
    to: allLabelsRoute,
    actionItems: [
      {
        title: 'Tag settings',
        icon: 'i-lucide-settings-2',
        to: labelsSettingsRoute,
      },
    ],
    children: [
      {
        name: 'VIP-1',
        label: 'VIP',
        to: { name: 'label_conversations', params: { label: 'VIP' } },
      },
    ],
  },
];

const mountComponent = (props = {}) =>
  mount(SidebarCollapsedPopover, {
    props: {
      label: 'Conversations',
      triggerRect: { top: 20, left: 0, bottom: 60, right: 40 },
      children: defaultChildren,
      ...props,
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

  it('opens the subgroup route when clicking a linkable subgroup label', async () => {
    const wrapper = mountComponent();
    const labelsButton = wrapper
      .findAll('button')
      .find(button => button.text().includes('Tags'));

    expect(labelsButton?.exists()).toBe(true);

    await labelsButton.trigger('click');

    expect(routerPush).toHaveBeenCalledWith(allLabelsRoute);
    expect(wrapper.emitted('close')).toBeTruthy();
  });

  it('still expands linkable subgroups from the chevron control', async () => {
    const wrapper = mountComponent();
    const toggleButton = wrapper.find('button[title="Tags"]');

    expect(toggleButton.exists()).toBe(true);

    await toggleButton.trigger('click');

    expect(routerPush).not.toHaveBeenCalled();
    expect(wrapper.text()).toContain('VIP');
  });

  it('renders an active linkable subgroup even without accessible subchildren', () => {
    const wrapper = mountComponent({
      activeChildNames: ['Channels'],
      children: [
        {
          name: 'Channels',
          label: 'Channels',
          icon: 'i-lucide-mailbox',
          badge: 12,
          to: allChannelsRoute,
          children: [],
        },
      ],
    });

    expect(wrapper.text()).toContain('Channels');
    expect(wrapper.find('.bg-n-alpha-2').exists()).toBe(true);
  });

  it('auto-expands a subgroup when the subgroup header is active', async () => {
    const wrapper = mountComponent({
      activeChildNames: ['Channels'],
      children: [
        {
          name: 'Channels',
          label: 'Channels',
          icon: 'i-lucide-mailbox',
          to: allChannelsRoute,
          children: [
            {
              name: 'WhatsApp-1',
              label: 'WhatsApp',
              to: { name: 'inbox_dashboard' },
            },
          ],
        },
      ],
    });

    await nextTick();
    await nextTick();

    expect(wrapper.text()).toContain('WhatsApp');
  });

  it('renders unread badges in the collapsed sidebar popover', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').text()).toBe(
      '999+'
    );
  });
});
