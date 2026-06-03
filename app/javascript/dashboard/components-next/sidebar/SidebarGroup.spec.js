import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';

import SidebarGroup from './SidebarGroup.vue';

const { expandedItem, routeState, routerPush, setExpandedItem } = vi.hoisted(
  () => {
    const expandedItemState = { value: null };

    return {
      expandedItem: expandedItemState,
      routeState: {
        name: 'home',
        path: '/home',
        query: { status: 'open' },
        params: {},
      },
      routerPush: vi.fn(),
      setExpandedItem: vi.fn(name => {
        expandedItemState.value = name;
      }),
    };
  }
);

vi.mock('vue-router', () => ({
  useRoute: () => routeState,
  useRouter: () => ({ push: routerPush }),
}));

vi.mock('./provider', () => ({
  usePopoverState: () => ({
    activePopover: { value: null },
    setActivePopover: vi.fn(),
    closeActivePopover: vi.fn(),
    scheduleClose: vi.fn(),
    cancelClose: vi.fn(),
  }),
  useSidebarContext: () => ({
    expandedItem,
    setExpandedItem,
    resolvePath: to => to?.path || `/${to?.name || ''}`,
    resolvePermissions: () => [],
    resolveFeatureFlag: () => '',
    isAllowed: () => true,
    isCollapsed: false,
    isResizing: { value: false },
  }),
}));

const homeRoute = {
  name: 'home',
  path: '/home',
  query: { status: 'open' },
};

const mountComponent = () =>
  mount(SidebarGroup, {
    props: {
      name: 'Conversation',
      label: 'Conversations',
      icon: 'i-lucide-message-circle',
      to: homeRoute,
      children: [
        {
          name: 'Channels',
          label: 'Channels',
          icon: 'i-lucide-mailbox',
          to: homeRoute,
          activeOn: ['home'],
          suppressHeaderActiveWhenChildActive: true,
          children: [
            {
              name: 'WhatsApp-1',
              label: 'WhatsApp',
              to: {
                name: 'inbox_dashboard',
                path: '/inboxes/1',
                params: { inbox_id: 1 },
              },
              activeOn: ['inbox_dashboard'],
            },
          ],
        },
      ],
    },
    global: {
      stubs: {
        Policy: {
          template: '<li><slot /></li>',
        },
        Icon: {
          props: ['icon'],
          template: '<span data-test-id="icon" :data-icon="icon" />',
        },
        SidebarGroupHeader: {
          props: ['label'],
          emits: ['toggle'],
          template:
            '<button data-test-id="group-header" type="button" @click="$emit(\'toggle\')">{{ label }}</button>',
        },
        SidebarSubGroup: {
          props: ['label', 'headerActive', 'activeChildNames', 'children'],
          template:
            '<div data-test-id="sidebar-subgroup" :data-label="label" :data-header-active="headerActive ? \'true\' : \'false\'" :data-active-child-names="activeChildNames.join(\',\')" />',
        },
        SidebarGroupLeaf: true,
        SidebarGroupEmptyLeaf: true,
        SidebarCollapsedPopover: true,
      },
    },
  });

describe('SidebarGroup', () => {
  beforeEach(() => {
    expandedItem.value = null;
    routerPush.mockClear();
    setExpandedItem.mockClear();
    Object.assign(routeState, {
      name: 'home',
      path: '/home',
      query: { status: 'open' },
      params: {},
    });
  });

  it('treats a linkable subgroup header as the active child route', async () => {
    const wrapper = mountComponent();

    await nextTick();
    await nextTick();

    expect(setExpandedItem).toHaveBeenCalledWith('Conversation');

    const subGroup = wrapper.find('[data-test-id="sidebar-subgroup"]');

    expect(subGroup.attributes('data-header-active')).toBe('true');
    expect(subGroup.attributes('data-active-child-names')).toBe('Channels');
  });
});
