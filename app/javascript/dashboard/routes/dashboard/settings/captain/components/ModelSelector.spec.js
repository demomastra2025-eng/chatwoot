import { shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import ModelSelector from './ModelSelector.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key} ${JSON.stringify(params)}` : key),
  }),
}));

const mountComponent = () =>
  shallowMount(ModelSelector, {
    props: {
      featureKey: 'assistant',
      title: 'AI agent model',
      description: 'Select a model for the customer-facing agent.',
      isAllowed: true,
    },
    global: {
      stubs: {
        ModelDropdown: true,
      },
    },
  });

describe('Captain model selector diagnostics', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  it('shows backend diagnostic reasons for a selected hidden or incompatible model', () => {
    const store = useCaptainConfigStore();
    store.applyPayload({
      features: {
        assistant: {
          selected: 'gpt-4.1',
          default: 'openai/gpt-4.1',
          models: [
            {
              id: 'openai/gpt-4.1',
              display_name: 'GPT 4.1 via OpenRouter',
              provider: 'openrouter',
              provider_configured: true,
            },
          ],
          selected_diagnostics: {
            allowed: false,
            reasons: [
              {
                code: 'direct_provider_disabled',
                message:
                  'Direct provider models are disabled for normal Captain settings.',
              },
              {
                code: 'tool_calling_unsupported',
                message: 'Model does not support tool calling.',
              },
            ],
          },
        },
      },
    });

    const wrapper = mountComponent();
    const diagnostics = wrapper.find(
      '[data-test="selected-model-diagnostics"]'
    );

    expect(diagnostics.exists()).toBe(true);
    expect(diagnostics.text()).toContain('gpt-4.1');
    expect(diagnostics.text()).toContain(
      'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.DIRECT_PROVIDER_DISABLED'
    );
    expect(diagnostics.text()).toContain(
      'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.TOOL_CALLING_UNSUPPORTED'
    );
  });

  it('does not show diagnostics when the selected model is allowed', () => {
    const store = useCaptainConfigStore();
    store.applyPayload({
      features: {
        assistant: {
          selected: 'openai/gpt-4.1',
          models: [
            {
              id: 'openai/gpt-4.1',
              display_name: 'GPT 4.1 via OpenRouter',
              provider: 'openrouter',
              provider_configured: true,
            },
          ],
          selected_diagnostics: {
            allowed: true,
            reasons: [],
          },
        },
      },
    });

    const wrapper = mountComponent();

    expect(
      wrapper.find('[data-test="selected-model-diagnostics"]').exists()
    ).toBe(false);
  });

  it('renders a fixed audio model without a dropdown even if a stale selection is present', () => {
    const store = useCaptainConfigStore();
    store.applyPayload({
      features: {
        audio_transcription: {
          selected: 'openai/gpt-audio-mini',
          models: [{ id: 'openai/gpt-audio-mini', provider_configured: true }],
        },
      },
    });

    const wrapper = shallowMount(ModelSelector, {
      props: {
        featureKey: 'audio_transcription',
        title: 'Audio recognition model',
        description: 'Transcription model is fixed.',
        fixedModel: 'openai/gpt-4o-transcribe',
        isAllowed: true,
      },
    });

    expect(wrapper.find('[data-test="fixed-model"]').text()).toContain(
      'openai/gpt-4o-transcribe'
    );
    expect(wrapper.findComponent({ name: 'ModelDropdown' }).exists()).toBe(
      false
    );
  });

  it('renders the old server selection read-only without a model choice', () => {
    const store = useCaptainConfigStore();
    store.applyPayload({
      features: {
        audio_transcription: {
          selected: 'openai/gpt-4o-mini-transcribe',
          models: [{ id: 'openai/gpt-audio-mini', provider_configured: true }],
        },
      },
    });

    const wrapper = shallowMount(ModelSelector, {
      props: {
        featureKey: 'audio_transcription',
        title: 'Audio recognition model',
        description: 'Old server is still responding.',
        readOnlyModel: 'openai/gpt-4o-mini-transcribe',
        isAllowed: true,
      },
    });

    expect(wrapper.find('[data-test="legacy-model"]').text()).toContain(
      'openai/gpt-4o-mini-transcribe'
    );
    expect(wrapper.find('[data-test="fixed-model"]').exists()).toBe(false);
    expect(wrapper.findComponent({ name: 'ModelDropdown' }).exists()).toBe(
      false
    );
  });
});
