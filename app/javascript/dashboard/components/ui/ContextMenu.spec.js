import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import ContextMenu from './ContextMenu.vue';

const teleportStub = {
  template: '<div><slot /></div>',
};

const mountComponent = props =>
  mount(ContextMenu, {
    props: {
      x: 12,
      y: 24,
      ...props,
    },
    slots: {
      default: '<div data-test-id="context-menu-content">Actions</div>',
    },
    global: {
      stubs: {
        TeleportWithDirection: teleportStub,
      },
    },
  });

describe('ContextMenu', () => {
  it('renders mobile context menus as a bottom sheet and closes on backdrop tap', async () => {
    const wrapper = mountComponent({ mobile: true });

    const backdrop = wrapper.find(
      '[data-test-id="mobile-context-menu-backdrop"]'
    );
    const sheet = wrapper.find('[data-test-id="mobile-context-menu-sheet"]');

    expect(backdrop.exists()).toBe(true);
    expect(sheet.exists()).toBe(true);
    expect(sheet.classes()).toContain('bottom-3');
    expect(wrapper.find('[data-test-id="context-menu-content"]').exists()).toBe(
      true
    );

    await backdrop.trigger('click');

    expect(wrapper.emitted('close')).toHaveLength(1);
  });

  it('keeps desktop context menus positioned by coordinates', () => {
    const wrapper = mountComponent();

    expect(
      wrapper.find('[data-test-id="mobile-context-menu-backdrop"]').exists()
    ).toBe(false);
    expect(wrapper.find('[tabindex="0"]').attributes('style')).toContain(
      'top: 24px'
    );
  });
});
