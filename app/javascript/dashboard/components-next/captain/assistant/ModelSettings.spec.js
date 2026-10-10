import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import ModelSettings from './ModelSettings.vue';
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
const stubs = {
  Button: {
    props: ['disabled'],
    emits: ['click'],
    template: '<button :disabled="disabled" @click="$emit(\'click\')" />',
  },
  Select: {
    props: ['modelValue', 'options'],
    template:
      '<select><option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option></select>',
  },
};

describe('confirmed model settings', () => {
  it('hides all controls until the gear opens and omits unknown parameter controls', async () => {
    const wrapper = mount(ModelSettings, {
      props: {
        models: [{ value: 'unknown', label: 'Unknown model' }],
        metadata: {},
      },
      global: { stubs },
    });
    expect(wrapper.find('select').exists()).toBe(false);
    await wrapper.get('[data-test="model-settings-toggle"]').trigger('click');
    expect(wrapper.findAll('select')).toHaveLength(1);
    expect(wrapper.find('[data-test="model-temperature"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-test="model-reasoning"]').exists()).toBe(false);
  });
  it('shows only metadata-confirmed effort choices and clears settings when the model contract changes', async () => {
    const wrapper = mount(ModelSettings, {
      props: {
        temperature: 0.4,
        effort: 'high',
        metadata: {
          supports_temperature: true,
          reasoning_efforts: ['low', 'high'],
        },
      },
      global: { stubs },
    });
    await wrapper.get('[data-test="model-settings-toggle"]').trigger('click');
    const choices = wrapper
      .get('[data-test="model-reasoning"]')
      .findAll('option')
      .map(option => option.attributes('value'));
    expect(choices).toEqual(['', 'low', 'high']);
    await wrapper.setProps({
      metadata: { supports_temperature: false, reasoning_efforts: ['low'] },
    });
    expect(wrapper.emitted('update:temperature')).toContainEqual([null]);
    expect(wrapper.emitted('update:effort')).toContainEqual(['']);
    expect(wrapper.find('[data-test="model-temperature"]').exists()).toBe(
      false
    );
  });
});
