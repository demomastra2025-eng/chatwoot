import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';

import SidebarGroup from './SidebarGroup.vue';

const {
  expandedItem,
  routeState,
  routerPush,
  setExpandedItem,
  sidebarCollapsed,
} = vi.hoisted(() => {
  const expandedItemState = { value: null };

  return {
    expandedItem: expandedItemState,
    sidebarCollapsed: { value: false },
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
});

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
    isCollapsed: sidebarCollapsed.value,
    isResizing: { value: false },
  }),
}));

const homeRoute = {
  name: 'home',
  path: '/home',
  query: { status: 'open' },
};

const mountComponent = (props = {}) =>
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
        {
          name: 'Labels',
          label: 'Tags',
          icon: 'i-lucide-tag',
          to: homeRoute,
          activeOn: [],
          suppressExactPathActive: true,
          suppressHeaderActiveWhenChildActive: true,
          children: [
            {
              name: 'VIP-1',
              label: 'VIP',
              to: {
                name: 'label_conversations',
                path: '/label/VIP',
                params: { label: 'VIP' },
              },
              activeOn: ['label_conversations'],
            },
          ],
        },
        {
          name: 'Teams',
          label: 'Teams',
          icon: 'i-lucide-users',
          to: homeRoute,
          activeOn: [],
          suppressExactPathActive: true,
          suppressHeaderActiveWhenChildActive: true,
          children: [
            {
              name: 'Sales-1',
              label: 'Sales',
              to: {
                name: 'team_conversations',
                path: '/team/1',
                params: { teamId: 1 },
              },
            },
          ],
        },
      ],
      ...props,
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
          props: [
            'label',
            'headerActive',
            'activeChildNames',
            'children',
            'to',
          ],
          template:
            '<div data-test-id="sidebar-subgroup" :data-label="label" :data-header-active="headerActive ? \'true\' : \'false\'" :data-has-to="to ? \'true\' : \'false\'" :data-active-child-names="activeChildNames.join(\',\')" />',
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
    sidebarCollapsed.value = false;
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

  it('does not highlight the Tags subgroup on the unfiltered all-tags route', async () => {
    const wrapper = mountComponent();

    await nextTick();
    await nextTick();

    const tagsSubGroup = wrapper
      .findAll('[data-test-id="sidebar-subgroup"]')
      .find(node => node.attributes('data-label') === 'Tags');

    expect(tagsSubGroup.attributes('data-header-active')).toBe('false');
    expect(tagsSubGroup.attributes('data-active-child-names')).toBe('Channels');
  });

  it('highlights only the concrete tag child on a tag-filtered route', async () => {
    Object.assign(routeState, {
      name: 'label_conversations',
      path: '/label/VIP',
      query: { status: 'open' },
      params: { label: 'VIP' },
    });

    const wrapper = mountComponent();

    await nextTick();
    await nextTick();

    const tagsSubGroup = wrapper
      .findAll('[data-test-id="sidebar-subgroup"]')
      .find(node => node.attributes('data-label') === 'Tags');

    expect(tagsSubGroup.attributes('data-header-active')).toBe('false');
    expect(tagsSubGroup.attributes('data-active-child-names')).toBe('VIP-1');
  });

  it('gives the Teams subgroup a clear-filter header like Tags', async () => {
    const wrapper = mountComponent();

    await nextTick();
    await nextTick();

    const teamsSubGroup = wrapper
      .findAll('[data-test-id="sidebar-subgroup"]')
      .find(node => node.attributes('data-label') === 'Teams');

    expect(teamsSubGroup.attributes('data-has-to')).toBe('true');
    expect(teamsSubGroup.attributes('data-header-active')).toBe('false');
  });

  it('highlights only the concrete team child on a team-filtered route', async () => {
    Object.assign(routeState, {
      name: 'team_conversations',
      path: '/team/1',
      query: { status: 'open' },
      params: { teamId: '1' },
    });

    const wrapper = mountComponent();

    await nextTick();
    await nextTick();

    const teamsSubGroup = wrapper
      .findAll('[data-test-id="sidebar-subgroup"]')
      .find(node => node.attributes('data-label') === 'Teams');

    expect(teamsSubGroup.attributes('data-header-active')).toBe('false');
    expect(teamsSubGroup.attributes('data-active-child-names')).toBe('Sales-1');
  });

  it('opens the configured default child when clicking a collapsed group', async () => {
    sidebarCollapsed.value = true;
    const touchesRoute = { name: 'outbound_touches_index' };
    const wrapper = mountComponent({
      name: 'Campaigns',
      label: 'Outbound',
      icon: 'i-lucide-send',
      to: null,
      defaultChildName: 'Touches',
      children: [
        {
          name: 'Templates',
          label: 'Templates',
          to: { name: 'outbound_templates_index' },
        },
        {
          name: 'Touches',
          label: 'Touches',
          to: touchesRoute,
        },
      ],
    });

    await wrapper.find('button[title="Outbound"]').trigger('click');

    expect(setExpandedItem).toHaveBeenCalledWith('Campaigns');
    expect(routerPush).toHaveBeenCalledWith(touchesRoute);
  });

  it('does not select an action-only collapsed group for a secondary column', async () => {
    sidebarCollapsed.value = true;
    const wrapper = mountComponent({
      name: 'CRM',
      label: 'Pipelines',
      icon: 'i-lucide-filter',
      to: { name: 'crm_deals_index' },
      actionTo: { name: 'crm_settings_index' },
      actionIcon: 'i-lucide-settings-2',
      children: undefined,
    });

    await wrapper.find('[title="Pipelines"]').trigger('click');

    expect(setExpandedItem).toHaveBeenCalledWith(null);
  });
});
