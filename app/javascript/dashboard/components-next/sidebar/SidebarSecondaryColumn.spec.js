import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import SidebarSecondaryColumn from './SidebarSecondaryColumn.vue';

const { routeState, routerPush } = vi.hoisted(() => ({
  routeState: {
    name: 'conversation_workflow_index',
    path: '/settings/conversations',
  },
  routerPush: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRoute: () => routeState,
  useRouter: () => ({ push: routerPush }),
}));

vi.mock('./provider', () => ({
  useSidebarContext: () => ({
    isAllowed: () => true,
    resolveFeatureFlag: () => '',
    resolvePermissions: () => [],
    resolvePath: to => to?.path || `/${to?.name || ''}`,
  }),
}));

vi.mock('next/icon/Icon.vue', () => ({
  default: {
    name: 'Icon',
    props: ['icon'],
    template: '<span data-test-id="icon" :data-icon="icon" />',
  },
}));

const mountComponent = props =>
  mount(SidebarSecondaryColumn, {
    props: {
      label: 'Conversations',
      children: [],
      activeChildNames: [],
      ...props,
    },
    global: {
      stubs: {
        SidebarGroupLeaf: true,
        SidebarSubGroup: {
          props: ['label', 'icon', 'children'],
          template: '<div data-test="sidebar-subgroup-stub" />',
        },
        SidebarAssigneeTabs: true,
      },
    },
  });

describe('SidebarSecondaryColumn', () => {
  it('renders multiple header actions and calls action handlers', async () => {
    const openCompose = vi.fn();
    const wrapper = mountComponent({
      actionItems: [
        {
          key: 'settings',
          label: 'Settings',
          icon: 'i-lucide-settings-2',
          to: { name: 'conversation_workflow_index' },
        },
        {
          key: 'compose',
          label: 'New message',
          icon: 'i-lucide-plus',
          handler: openCompose,
        },
      ],
    });

    const actionButtons = wrapper.findAll('header button');

    expect(actionButtons).toHaveLength(2);
    expect(actionButtons[0].attributes('title')).toBe('Settings');
    expect(actionButtons[1].attributes('title')).toBe('New message');

    await actionButtons[1].trigger('click');

    expect(openCompose).toHaveBeenCalledTimes(1);
    expect(routerPush).not.toHaveBeenCalled();
  });

  it('renders flat section labels only when they contain navigation items', () => {
    const wrapper = mountComponent({
      children: [
        {
          type: 'section',
          name: 'Settings Section Company',
          label: 'Company',
        },
        {
          name: 'Workspace',
          label: 'Company profile',
          to: { name: 'general_settings_index' },
        },
        {
          type: 'section',
          name: 'Settings Section Empty',
          label: 'Empty',
        },
      ],
    });

    const sectionLabels = wrapper.findAll(
      '[data-test="sidebar-section-label"]'
    );
    expect(sectionLabels).toHaveLength(1);
    expect(sectionLabels[0].text()).toBe('Company');
    expect(wrapper.text()).not.toContain('Empty');
  });

  it('omits a subgroup separator when the child requests a compact transition', () => {
    const child = name => ({
      name,
      label: name,
      icon: 'i-lucide-folder',
      children: [{ name: `${name} child`, to: { name } }],
    });
    const wrapper = mountComponent({
      children: [
        child('Pipelines'),
        { ...child('Labels'), hideTopSeparator: true },
        child('Folders'),
      ],
    });

    expect(
      wrapper.findAll('[data-test="sidebar-group-separator"]')
    ).toHaveLength(1);
  });
});
