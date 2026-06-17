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
        SidebarSubGroup: true,
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
});
