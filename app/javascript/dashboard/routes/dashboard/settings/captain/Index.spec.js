import { shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import Index from './Index.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key} ${JSON.stringify(params)}` : key),
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    isOnChatwootCloud: { value: false },
  }),
}));

vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({
    captainEnabled: true,
  }),
}));

vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({
    isEnterprise: true,
    enterprisePlanName: 'enterprise',
  }),
}));

const basePayload = ({ audioModel }) => ({
  providers: {
    openrouter: { display_name: 'OpenRouter' },
  },
  features: {
    editor: { models: [] },
    assistant: { models: [] },
    copilot: { models: [] },
    moderation: { models: [] },
    image_recognition: { models: [] },
    help_center_search: { models: [], enabled: true },
    label_suggestion: { models: [], enabled: false },
    audio_transcription: {
      enabled: true,
      selected: audioModel.id,
      default: audioModel.id,
      models: [audioModel],
    },
  },
  runtime: {
    audio_transcription_prompt: 'Use the support context.',
    knowledge_chunk_size: 20000,
  },
  runtime_metadata: {
    knowledge_indexing: {
      chunk_size_options: [],
    },
  },
  provider_credentials: {
    openrouter: {
      display_name: 'OpenRouter',
      source: 'global',
      account_configured: false,
      global_configured: true,
    },
  },
});

const mountComponent = store => {
  vi.spyOn(store, 'fetch').mockResolvedValue();

  return shallowMount(Index, {
    global: {
      stubs: {
        SettingsLayout: {
          template: '<main><slot name="header" /><slot name="body" /></main>',
        },
        BaseSettingsHeader: true,
        SectionLayout: { template: '<section><slot /></section>' },
        ModelSelector: {
          props: [
            'featureKey',
            'title',
            'description',
            'models',
            'showControls',
          ],
          template:
            '<section :data-feature-key="featureKey"><span v-for="model in models || []" :key="model.id" data-test="model-id">{{ model.id }}</span><slot name="controls" /></section>',
        },
        ModelDropdown: true,
        NextButton: { template: '<button type="button"><slot /></button>' },
        Icon: true,
        Input: true,
        NextSelect: true,
        Switch: true,
        TextArea: {
          template: '<textarea data-test="audio-transcription-prompt" />',
        },
        CaptainPaywall: true,
      },
    },
  });
};

describe('Captain settings OpenRouter UX', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  it('renders only the OpenRouter provider key card in normal Captain settings', () => {
    const store = useCaptainConfigStore();
    store.applyPayload({
      ...basePayload({
        audioModel: {
          id: 'openai/gpt-audio-mini',
          display_name: 'GPT Audio Mini',
          provider: 'openrouter',
          provider_configured: true,
          type: 'chat',
          capabilities: ['audio_input', 'text_output', 'transcription'],
        },
      }),
      providers: {
        openrouter: { display_name: 'OpenRouter' },
        openai: { display_name: 'OpenAI' },
        anthropic: { display_name: 'Anthropic' },
        gemini: { display_name: 'Gemini' },
      },
      provider_credentials: {
        openrouter: { display_name: 'OpenRouter', source: 'global' },
        openai: { display_name: 'OpenAI', source: 'global' },
        anthropic: { display_name: 'Anthropic', source: 'global' },
        gemini: { display_name: 'Gemini', source: 'global' },
      },
    });

    const wrapper = mountComponent(store);

    expect(wrapper.text()).toContain('OpenRouter');
    expect(wrapper.text()).not.toContain('OpenAI');
    expect(wrapper.text()).not.toContain('Anthropic');
    expect(wrapper.text()).not.toContain('Gemini');
  });

  it('hides the audio prompt control for native transcription endpoint models', () => {
    const store = useCaptainConfigStore();
    store.applyPayload(
      basePayload({
        audioModel: {
          id: 'openai/whisper-large-v3',
          display_name: 'Whisper Large v3',
          provider: 'openrouter',
          provider_configured: true,
          type: 'transcription',
          capabilities: ['audio_input', 'transcription'],
        },
      })
    );

    const wrapper = mountComponent(store);

    expect(
      wrapper.find('[data-test="audio-transcription-prompt"]').exists()
    ).toBe(false);
  });

  it('keeps the audio prompt control for prompt-aware audio chat models', () => {
    const store = useCaptainConfigStore();
    store.applyPayload(
      basePayload({
        audioModel: {
          id: 'openai/gpt-audio-mini',
          display_name: 'GPT Audio Mini',
          provider: 'openrouter',
          provider_configured: true,
          type: 'chat',
          capabilities: ['audio_input', 'text_output', 'transcription'],
        },
      })
    );

    const wrapper = mountComponent(store);

    expect(
      wrapper.find('[data-test="audio-transcription-prompt"]').exists()
    ).toBe(true);
  });

  it('filters embedding models by the selected knowledge chunk constraints', () => {
    const audioModel = {
      id: 'openai/gpt-audio-mini',
      display_name: 'GPT Audio Mini',
      provider: 'openrouter',
      provider_configured: true,
      type: 'chat',
      capabilities: ['audio_input', 'text_output', 'transcription'],
    };
    const store = useCaptainConfigStore();
    store.applyPayload({
      ...basePayload({ audioModel }),
      features: {
        ...basePayload({ audioModel }).features,
        help_center_search: {
          enabled: true,
          selected: 'openai/text-embedding-3-small',
          models: [
            {
              id: 'openai/text-embedding-3-small',
              provider: 'openrouter',
              provider_configured: true,
              type: 'embedding',
              capabilities: ['embedding'],
              context_length: 8192,
              embedding_dimensions: 1536,
            },
            {
              id: 'openai/text-embedding-small-context',
              provider: 'openrouter',
              provider_configured: true,
              type: 'embedding',
              capabilities: ['embedding'],
              context_length: 1024,
              embedding_dimensions: 1536,
            },
            {
              id: 'openai/text-embedding-wrong-dimensions',
              provider: 'openrouter',
              provider_configured: true,
              type: 'embedding',
              capabilities: ['embedding'],
              context_length: 8192,
              embedding_dimensions: 512,
            },
          ],
        },
      },
      runtime_metadata: {
        knowledge_indexing: {
          vector_dimensions: 1536,
          chunk_size_options: [
            {
              value: 20000,
              estimated_tokens: 5000,
              available_model_count: 1,
            },
          ],
        },
      },
    });

    const wrapper = mountComponent(store);
    const embeddingBlock = wrapper.find(
      '[data-feature-key="help_center_search"]'
    );

    expect(embeddingBlock.text()).toContain('openai/text-embedding-3-small');
    expect(embeddingBlock.text()).not.toContain(
      'openai/text-embedding-small-context'
    );
    expect(embeddingBlock.text()).not.toContain(
      'openai/text-embedding-wrong-dimensions'
    );
  });
});
