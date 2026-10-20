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
      <option v-for="option in options" :key="option.value" :value="option.value" :data-icon="option.icon || ''">
        {{ option.label }}
      </option>
    </select>
  `,
};

const DEFAULT_MODEL = {
  id: 'openai/gpt-6-luna',
  provider: 'openrouter',
  display_name: 'GPT-6 Luna',
  supports_temperature: false,
  reasoning_efforts: [],
};
const SMART_MODEL = {
  id: 'claude-sonnet-4-6',
  provider: 'anthropic',
  display_name: 'Claude Sonnet 4.6',
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
      icon: option.attributes('data-icon'),
    }));

describe('AgentModelBlock', () => {
  beforeEach(() => {
    configStore.models = [DEFAULT_MODEL, SMART_MODEL, LEGACY_MODEL];
    configStore.selected = 'openai/gpt-6-luna';
  });

  it('shows clean model names without default suffix and attaches ChatGPT and Claude logos', () => {
    const wrapper = mountBlock({ model: '' });

    const options = modelOptions(wrapper);
    expect(options).toEqual([
      {
        value: 'openai/gpt-6-luna',
        label: 'GPT-6 Luna',
        icon: 'i-ri-openai-fill',
      },
      {
        value: 'claude-sonnet-4-6',
        label: 'Claude Sonnet 4.6',
        icon: 'i-logos-claude-icon',
      },
    ]);
    expect(wrapper.find('[data-test="model-temperature"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-test="model-reasoning"]').exists()).toBe(false);
  });

  it('shows concrete reasoning levels without a default option', () => {
    const wrapper = mountBlock({ model: 'claude-sonnet-4-6', effort: '' });

    expect(wrapper.find('[data-test="model-temperature"]').exists()).toBe(true);
    const reasoningSelect = wrapper.get('[data-test="model-reasoning"] select');
    expect(
      reasoningSelect.findAll('option').map(option => option.attributes('value'))
    ).toEqual(['none', 'low', 'high']);
    expect(reasoningSelect.element.value).toBe('low');
    expect(wrapper.text()).toContain('CAPTAIN.AGENT_PAGE.MODEL.SELECT_LABEL');
  });

  it('stores the platform default as an empty model', async () => {
    const wrapper = mountBlock({ model: 'claude-sonnet-4-6' });

    await wrapper.find('select').setValue('openai/gpt-6-luna');
    expect(wrapper.emitted('update:model')).toEqual([['']]);

    await wrapper.find('select').setValue('claude-sonnet-4-6');
    expect(wrapper.emitted('update:model')[1]).toEqual(['claude-sonnet-4-6']);
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
        playground_model: { id: 'openai/gpt-6-luna', display_name: 'GPT-6 Luna' },
      },
    });

    expect(wrapper.find('select').exists()).toBe(false);
    expect(wrapper.get('[data-test="agent-model-name"]').text()).toBe(
      'GPT-6 Luna'
    );
  });
});
