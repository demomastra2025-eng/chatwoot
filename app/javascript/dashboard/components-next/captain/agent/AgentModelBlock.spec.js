import { beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

const configStore = {
  models: [],
  selected: '',
  getModelsForFeature: vi.fn(() => configStore.models),
  getSelectedModelForFeature: vi.fn(() => configStore.selected),
};

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

vi.mock('dashboard/store/captain/preferences', () => ({
  useCaptainConfigStore: () => configStore,
}));

const { default: AgentModelBlock } = await import('./AgentModelBlock.vue');

const SelectStub = {
  props: ['modelValue', 'options', 'disabled'],
  emits: ['update:modelValue'],
  template: `
    <select
      :value="modelValue"
      :disabled="disabled"
      @change="$emit('update:modelValue', $event.target.value)"
    >
      <option v-for="option in options" :key="option.value" :value="option.value">
        {{ option.label }}
      </option>
    </select>
  `,
};

const DEFAULT_MODEL = {
  id: 'default-model',
  display_name: 'Default model',
  supports_temperature: false,
  reasoning_efforts: [],
};
const SMART_MODEL = {
  id: 'smart-model',
  display_name: 'Smart model',
  supports_temperature: true,
  reasoning_efforts: ['none', 'low', 'high'],
};
const LEGACY_MODEL = {
  id: 'legacy-model',
  display_name: 'Legacy model',
  current_only: true,
  supports_temperature: false,
  reasoning_efforts: [],
};

const mountBlock = (props = {}) =>
  mount(AgentModelBlock, {
    props: { assistant: { id: 5, config: {} }, ...props },
    global: { stubs: { Select: SelectStub } },
  });

const modelOptions = wrapper =>
  wrapper
    .findAll('select')[0]
    .findAll('option')
    .map(option => ({
      value: option.attributes('value'),
      label: option.text(),
    }));

describe('AgentModelBlock', () => {
  beforeEach(() => {
    configStore.models = [DEFAULT_MODEL, SMART_MODEL, LEGACY_MODEL];
    configStore.selected = 'default-model';
  });

  it('marks the platform default model and hides parameters it does not support', () => {
    const wrapper = mountBlock({ model: '' });

    const options = modelOptions(wrapper);
    expect(options.map(option => option.value)).toEqual([
      'default-model',
      'smart-model',
    ]);
    expect(options[0].label).toBe(
      'Default model (CAPTAIN.AGENT_PAGE.MODEL.DEFAULT_MARK)'
    );
    expect(wrapper.find('[data-test="model-temperature"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-test="model-reasoning"]').exists()).toBe(false);
  });

  it('shows temperature and reasoning only when the selected model supports them', () => {
    const wrapper = mountBlock({ model: 'smart-model', effort: 'low' });

    expect(wrapper.find('[data-test="model-temperature"]').exists()).toBe(true);
    expect(
      wrapper
        .get('[data-test="model-reasoning"]')
        .findAll('option')
        .map(option => option.attributes('value'))
    ).toEqual(['', 'none', 'low', 'high']);
    expect(wrapper.text()).toContain('CAPTAIN.AGENT_PAGE.MODEL.SELECT_LABEL');
  });

  it('stores the platform default as an empty model', async () => {
    const wrapper = mountBlock({ model: 'smart-model' });

    await wrapper.find('select').setValue('default-model');
    expect(wrapper.emitted('update:model')).toEqual([['']]);

    await wrapper.find('select').setValue('smart-model');
    expect(wrapper.emitted('update:model')[1]).toEqual(['smart-model']);
  });

  it('keeps a current-only model visible while it is selected', () => {
    const wrapper = mountBlock({ model: 'legacy-model' });

    const legacy = modelOptions(wrapper).find(
      option => option.value === 'legacy-model'
    );
    expect(legacy.label).toBe(
      'Legacy model (CAPTAIN.AGENT_PAGE.MODEL.CURRENT_MARK)'
    );
  });

  it('shows only the model name without access to the model catalog', () => {
    configStore.models = [];
    configStore.selected = '';
    const wrapper = mountBlock({
      model: '',
      disabled: true,
      assistant: {
        id: 5,
        config: {},
        playground_model: { id: 'x', display_name: 'Platform model' },
      },
    });

    expect(wrapper.find('select').exists()).toBe(false);
    expect(wrapper.get('[data-test="agent-model-name"]').text()).toBe(
      'Platform model'
    );
  });
});
