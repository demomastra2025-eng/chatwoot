import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const { default: AgentReadToolsBlock } = await import(
  './AgentReadToolsBlock.vue'
);

const SwitchStub = {
  props: ['modelValue', 'disabled'],
  emits: ['update:modelValue'],
  template: `<input type="checkbox" :checked="modelValue" :disabled="disabled"
    @change="$emit('update:modelValue', $event.target.checked)" />`,
};

const mountBlock = (props = {}) =>
  mount(AgentReadToolsBlock, {
    props: {
      draft: { name: 'A', faqLookup: true, serviceSearch: true },
      ...props,
    },
    global: { stubs: { Switch: SwitchStub } },
  });

describe('AgentReadToolsBlock', () => {
  it('shows both switches on by default', () => {
    const wrapper = mountBlock();
    const switches = wrapper.findAll('input[type="checkbox"]');

    expect(switches).toHaveLength(2);
    expect(switches.map(item => item.element.checked)).toEqual([true, true]);
  });

  it('shows a switched-off tool as off', () => {
    const wrapper = mountBlock({
      draft: { faqLookup: false, serviceSearch: true },
    });

    expect(
      wrapper
        .findAll('input[type="checkbox"]')
        .map(item => item.element.checked)
    ).toEqual([false, true]);
  });

  it('emits the whole draft with the changed switch', async () => {
    const wrapper = mountBlock();
    const [faq, services] = wrapper.findAll('input[type="checkbox"]');

    await faq.setValue(false);
    await services.setValue(false);

    expect(wrapper.emitted('update:draft')).toEqual([
      [{ name: 'A', faqLookup: false, serviceSearch: true }],
      [{ name: 'A', faqLookup: true, serviceSearch: false }],
    ]);
  });

  it('cannot be changed by a viewer', () => {
    const wrapper = mountBlock({ disabled: true });

    expect(
      wrapper
        .findAll('input[type="checkbox"]')
        .every(item => item.element.disabled)
    ).toBe(true);
  });
});
