import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';

import Dialog from './Dialog.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('@vueuse/components', () => ({
  OnClickOutside: defineComponent({
    name: 'OnClickOutside',
    setup(_props, { slots }) {
      return () => h('div', slots.default?.());
    },
  }),
}));

vi.mock('dashboard/components-next/TeleportWithDirection.vue', () => ({
  default: defineComponent({
    name: 'TeleportWithDirection',
    setup(_props, { slots }) {
      return () => h('div', slots.default?.());
    },
  }),
}));

describe('Dialog', () => {
  it('names the dialog with its current visible title and unique heading id', async () => {
    const wrapper = mount(Dialog, { props: { title: 'Create contact' } });
    const dialog = wrapper.get('dialog');
    const heading = wrapper.get('h3');
    expect(dialog.attributes('aria-labelledby')).toBe(heading.attributes('id'));
    expect(heading.text()).toBe('Create contact');
    await wrapper.setProps({ title: 'Создать контакт' });
    expect(
      wrapper.get(`[id="${dialog.attributes('aria-labelledby')}"]`).text()
    ).toBe('Создать контакт');
    wrapper.unmount();
  });

  it('supports a 15 percent wider large dialog size', () => {
    const wrapper = mount(Dialog, {
      props: {
        width: 'lg-plus',
        renderOnOpenOnly: false,
      },
      global: {
        stubs: {
          Button: true,
        },
      },
    });

    expect(wrapper.find('dialog').classes()).toContain('max-w-[36.8rem]');
  });
});
