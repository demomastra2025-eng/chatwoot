import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import MenuItemWithSubmenu from './menuItemWithSubmenu.vue';

const mountComponent = props =>
  mount(MenuItemWithSubmenu, {
    props: {
      option: { icon: 'person-add', label: 'Assign agent' },
      ...props,
    },
    slots: {
      default: '<button data-test-id="submenu-action">Agent</button>',
    },
    global: {
      stubs: {
        FluentIcon: true,
        'fluent-icon': true,
      },
    },
  });

describe('MenuItemWithSubmenu', () => {
  it('opens submenu with tap in mobile mode', async () => {
    const wrapper = mountComponent({ mobile: true });

    const submenu = () => wrapper.find('.mobile-submenu');

    expect(submenu().classes()).toContain('hidden');

    await wrapper.trigger('click');

    expect(submenu().classes()).toContain('block');
    expect(wrapper.attributes('aria-expanded')).toBe('true');
  });

  it('keeps desktop submenu hover-driven by default', () => {
    const wrapper = mountComponent();

    const submenu = wrapper.find('.submenu');

    expect(submenu.exists()).toBe(true);
    expect(submenu.classes()).toContain('hidden');
    expect(wrapper.classes()).not.toContain('mobile-menu-with-submenu');
  });
});
