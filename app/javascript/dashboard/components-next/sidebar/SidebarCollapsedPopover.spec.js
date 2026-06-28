import { mount } from '@vue/test-utils';
import { describe, expect, it, beforeEach, vi } from 'vitest';
import { nextTick } from 'vue';

import SidebarCollapsedPopover from './SidebarCollapsedPopover.vue';

const { createLabelHandler, routerPush } = vi.hoisted(() => ({
  createLabelHandler: vi.fn(),
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
      {
        title: 'Create tag',
        icon: 'i-lucide-plus',
        handler: createLabelHandler,
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
    createLabelHandler.mockClear();
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

  it('runs subgroup action item handlers from the collapsed sidebar popover', async () => {
    const wrapper = mountComponent();
    const createButton = wrapper.find('button[title="Create tag"]');

    expect(createButton.exists()).toBe(true);

    await createButton.trigger('click');

    expect(createLabelHandler).toHaveBeenCalledTimes(1);
    expect(routerPush).not.toHaveBeenCalled();
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

  it('renders conversation tab totals as plain text in the collapsed popover', () => {
    const wrapper = mountComponent({
      children: [
        {
          name: 'Assignee:all',
          label: 'All',
          icon: 'i-lucide-users-round',
          count: 7,
          badge: 7,
          to: allChannelsRoute,
        },
      ],
    });
    const count = wrapper.find('[data-test-id="sidebar-plain-count"]');

    expect(count.text()).toBe('7');
    expect(count.classes()).toContain('text-xs');
    expect(count.classes()).toContain('font-medium');
    expect(count.classes()).not.toContain('bg-n-brand/10');
    expect(wrapper.find('[data-test-id="sidebar-unread-badge"]').exists()).toBe(
      false
    );
  });

  it('applies countClass to plain counts in the collapsed popover', () => {
    const wrapper = mountComponent({
      children: [
        {
          name: 'AppointmentStatus:confirmed',
          label: 'Подтвержден',
          icon: 'i-lucide-badge-check',
          count: 5,
          countClass: 'text-n-amber-11',
          to: allChannelsRoute,
        },
      ],
    });
    const count = wrapper.find('[data-test-id="sidebar-plain-count"]');

    expect(count.text()).toBe('5');
    expect(count.classes()).toContain('text-n-amber-11');
  });
});
