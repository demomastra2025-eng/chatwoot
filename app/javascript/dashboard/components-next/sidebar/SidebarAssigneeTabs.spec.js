import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import SidebarAssigneeTabs from './SidebarAssigneeTabs.vue';

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

const mountComponent = (props = {}) =>
  mount(SidebarAssigneeTabs, {
    props: {
      items: [
        {
          name: 'Assignee:all',
          label: 'All',
          count: 1234,
          to: { name: 'communication_threads_dashboard' },
        },
      ],
      activeChildNames: [],
      ...props,
    },
  });

describe('SidebarAssigneeTabs', () => {
  it('shows large assignee totals without capping', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('1234');
    expect(wrapper.text()).not.toContain('999+');
  });
});
