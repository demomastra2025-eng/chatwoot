import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import SelectMenu from './SelectMenu.vue';

const ButtonStub = {
  inheritAttrs: false,
  props: {
    label: { type: String, default: '' },
  },
  emits: ['click'],
  template: `
    <button v-bind="$attrs" type="button" @click="$emit('click')">
      <slot>{{ label }}</slot>
    </button>
  `,
};

const mountMenu = props =>
  mount(SelectMenu, {
    props: {
      label: 'Main pipeline',
      modelValue: '1',
      options: [
        { label: 'Main pipeline', value: '1' },
        { label: 'Sales', value: '2' },
      ],
      ...props,
    },
    global: {
      directives: { 'on-clickaway': {} },
      stubs: {
        Button: ButtonStub,
        Icon: true,
      },
    },
  });

describe('SelectMenu', () => {
  it('supports a transparent trigger and start-aligned bottom menu', async () => {
    const wrapper = mountMenu({
      highlightTrigger: false,
      subMenuAlign: 'start',
      subMenuPosition: 'bottom',
      triggerClass: 'hover:!bg-transparent',
      triggerAriaLabel: 'Select pipeline',
    });

    await wrapper.find('button').trigger('click');

    const trigger = wrapper.find('button');
    const menu = wrapper.find('.top-full');

    expect(trigger.classes()).toContain('hover:!bg-transparent');
    expect(trigger.attributes('aria-label')).toBe('Select pipeline');
    expect(trigger.classes()).not.toContain('!bg-n-slate-9/20');
    expect(menu.classes()).toContain('ltr:left-0');
    expect(menu.classes()).not.toContain('ltr:right-0');
  });

  it('emits the footer action and closes the menu', async () => {
    const wrapper = mountMenu({ actionLabel: 'Create pipeline' });

    await wrapper.find('button').trigger('click');
    const actionButton = wrapper
      .findAll('button')
      .find(button => button.text() === 'Create pipeline');
    await actionButton.trigger('click');

    expect(wrapper.emitted('action')).toHaveLength(1);
    expect(wrapper.find('.top-full').exists()).toBe(false);
  });
});
