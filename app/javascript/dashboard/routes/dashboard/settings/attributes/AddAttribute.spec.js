import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';

import AddAttribute from './AddAttribute.vue';

const dispatch = vi.fn(() => Promise.resolve());

const mountComponent = props =>
  mount(AddAttribute, {
    props: {
      onClose: vi.fn(),
      ...props,
    },
    global: {
      mocks: {
        $store: {
          dispatch,
          getters: {
            getUIFlags: { isCreating: false },
          },
        },
        $t: key => key,
      },
      stubs: {
        Checkbox: {
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template:
            '<input type="checkbox" :checked="modelValue" @change="$emit(\'update:modelValue\', $event.target.checked)" />',
        },
        NextButton: true,
        TagInput: true,
        WootInput: true,
        WootModal: {
          template: '<div><slot /></div>',
        },
        WootModalHeader: true,
        WootSelect: {
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template:
            '<select :value="modelValue" @change="$emit(\'update:modelValue\', Number($event.target.value))"><slot /></select>',
        },
      },
    },
  });

describe('AddAttribute', () => {
  it('defaults to the company attribute model when opened from the company tab', () => {
    const wrapper = mountComponent({ selectedAttributeModelTab: 2 });

    expect(wrapper.vm.attributeModel).toBe(2);
    expect(wrapper.find('select').element.value).toBe('2');
  });

  it('renders regex validation toggle with normal spacing and native v-model behavior', async () => {
    const wrapper = mountComponent();
    const regexToggle = wrapper.find('label.mt-2.mb-4');

    expect(regexToggle.exists()).toBe(true);
    expect(regexToggle.classes()).toContain('gap-3');
    expect(regexToggle.classes()).toContain('py-3');

    await regexToggle.find('input[type="checkbox"]').setValue(true);

    expect(wrapper.vm.regexEnabled).toBe(true);
  });

  it('clears regex config when a non-text attribute type is selected', async () => {
    const wrapper = mountComponent();

    await wrapper.setData({
      regexCue: 'Only digits',
      regexEnabled: true,
      regexPattern: '^\\d+$',
    });
    await wrapper.setData({ attributeType: 1 });
    await nextTick();

    expect(wrapper.vm.regexEnabled).toBe(false);
    expect(wrapper.vm.regexPattern).toBeNull();
    expect(wrapper.vm.regexCue).toBeNull();
  });
});
