import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

import DropdownItem from './DropdownItem.vue';
import { provideDropdownContext } from './provider';

const RouterLinkStub = {
  name: 'RouterLink',
  props: ['to'],
  template:
    '<a data-test-id="router-link" :data-to="JSON.stringify(to)"><slot /></a>',
};

const mountItem = ({ closeMenu, itemProps = '' } = {}) =>
  mount(
    {
      components: { DropdownItem },
      data() {
        return {
          itemClick: vi.fn(),
        };
      },
      setup() {
        provideDropdownContext({
          isOpen: ref(true),
          toggle: vi.fn(),
          closeMenu: closeMenu || vi.fn(),
        });
      },
      template: `
        <ul>
          <DropdownItem
            label="Employees"
            ${itemProps}
          />
        </ul>
      `,
    },
    {
      global: {
        stubs: {
          RouterLink: RouterLinkStub,
          'router-link': RouterLinkStub,
        },
      },
    }
  );

describe('DropdownItem', () => {
  it('defers closing router-link items until after the click event so navigation can consume it', async () => {
    vi.useFakeTimers();

    try {
      const closeMenu = vi.fn();
      const wrapper = mountItem({
        closeMenu,
        itemProps: ':link="{ name: \'agent_list\', params: { accountId: 1 } }"',
      });

      await wrapper.get('[data-test-id="router-link"]').trigger('click');

      expect(closeMenu).not.toHaveBeenCalled();

      await vi.runOnlyPendingTimersAsync();

      expect(closeMenu).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it('closes click action items immediately', async () => {
    const closeMenu = vi.fn();
    const wrapper = mountItem({
      closeMenu,
      itemProps: ':click="itemClick"',
    });

    await wrapper.get('button').trigger('click');

    expect(wrapper.vm.itemClick).toHaveBeenCalledTimes(1);
    expect(closeMenu).toHaveBeenCalledTimes(1);
  });

  it('keeps router-link items open when preserveOpen is enabled', async () => {
    vi.useFakeTimers();

    try {
      const closeMenu = vi.fn();
      const wrapper = mountItem({
        closeMenu,
        itemProps:
          ':link="{ name: \'agent_list\', params: { accountId: 1 } }" preserve-open',
      });

      await wrapper.get('[data-test-id="router-link"]').trigger('click');
      await vi.runOnlyPendingTimersAsync();

      expect(closeMenu).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });
});
