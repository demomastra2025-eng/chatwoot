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
  it('shows the model immediately and omits unknown parameter controls', () => {
    const wrapper = mount(ModelSettings, {
      props: {
        models: [{ value: 'unknown', label: 'Unknown model' }],
        metadata: {},
      },
      global: { stubs },
    });
    expect(wrapper.findAll('select')).toHaveLength(1);
    expect(wrapper.find('[data-test="model-settings-toggle"]').exists()).toBe(
      false
    );
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

  it('preserves saved parameters while preference metadata is loading', async () => {
    const wrapper = mount(ModelSettings, {
      props: { temperature: 0.7, effort: 'medium', metadata: {} },
      global: { stubs },
    });
    await wrapper.setProps({ metadata: {} });

    expect(wrapper.emitted('update:temperature')).toBeUndefined();
    expect(wrapper.emitted('update:effort')).toBeUndefined();

    await wrapper.setProps({
      metadata: {
        supports_temperature: true,
        reasoning_efforts: ['low', 'medium', 'high'],
      },
    });
    expect(wrapper.emitted('update:temperature')).toBeUndefined();
    expect(wrapper.emitted('update:effort')).toBeUndefined();
    expect(
      wrapper.get('[data-test="model-temperature"] input[type="range"]').element
        .value
    ).toBe('0.7');
    expect(
      wrapper
        .get('[data-test="model-reasoning"]')
        .findAll('option')
        .map(option => option.attributes('value'))
    ).toEqual(['', 'low', 'medium', 'high']);
    await wrapper.setProps({ metadata: {} });
    expect(wrapper.emitted('update:temperature')).toBeUndefined();
    expect(wrapper.emitted('update:effort')).toBeUndefined();
    await wrapper.setProps({
      metadata: { supports_temperature: false, reasoning_efforts: [] },
    });
    expect(wrapper.emitted('update:temperature')).toContainEqual([null]);
    expect(wrapper.emitted('update:effort')).toContainEqual(['']);
  });

  it('keeps the playground three-column grid and test model label by default', () => {
    const wrapper = mount(ModelSettings, {
      props: { metadata: {} },
      global: { stubs },
    });
    const grid = wrapper.get('[data-test="model-settings-grid"]');
    expect(grid.classes()).toContain('md:grid-cols-3');
    expect(grid.classes()).not.toContain('grid-cols-1');
    expect(wrapper.text()).toContain('CAPTAIN.PLAYGROUND.TEST_MODEL');
  });

  it('stacks the controls in one column and uses the given model label', () => {
    const wrapper = mount(ModelSettings, {
      props: {
        stacked: true,
        modelLabel: 'Agent model',
        metadata: {
          supports_temperature: true,
          reasoning_efforts: ['none', 'low'],
        },
      },
      global: { stubs },
    });
    const grid = wrapper.get('[data-test="model-settings-grid"]');
    expect(grid.classes()).toContain('grid-cols-1');
    expect(grid.classes()).not.toContain('md:grid-cols-3');
    expect(wrapper.text()).toContain('Agent model');
    expect(wrapper.text()).not.toContain('CAPTAIN.PLAYGROUND.TEST_MODEL');
    expect(
      wrapper
        .get('[data-test="model-reasoning"]')
        .findAll('option')
        .map(option => option.attributes('value'))
    ).toEqual(['', 'none', 'low']);
  });
});
