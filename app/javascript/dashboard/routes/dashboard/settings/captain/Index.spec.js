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
  usage: {
    currency: 'USD',
    windows: {
      today: {
        request_count: 2,
        estimated_cost: 0.25,
        total_tokens: 1000,
        cached_tokens: 100,
        reasoning_tokens: 50,
        error_count: 0,
      },
      month: {
        request_count: 10,
        estimated_cost: 1.5,
        total_tokens: 12000,
        cached_tokens: 1200,
        reasoning_tokens: 300,
        error_count: 1,
      },
    },
    budgets: {
      account_policy: {
        active: true,
        hard_stop: false,
        warning_threshold: 0.8,
        daily_budget: 5,
        monthly_budget: 100,
        daily: {
          spend: 0.25,
          limit: 5,
          remaining: 4.75,
          percent_used: 5,
          status: 'ok',
        },
        monthly: {
          spend: 1.5,
          limit: 100,
          remaining: 98.5,
          percent_used: 1.5,
          status: 'ok',
        },
      },
    },
    runtime_health: {
      total_events: 3,
      retry_count: 1,
      schema_invalid_count: 0,
      tool_failure_count: 0,
      last_event_at: '2026-05-31T10:00:00Z',
    },
    top_models: [
      {
        actual_model: 'openai/gpt-5.4',
        request_count: 10,
        total_tokens: 12000,
        estimated_cost: 1.5,
      },
    ],
    recent_errors: [],
  },
  runtime_metadata: {
    web_access: {
      provider: 'firecrawl',
      configured: true,
      search_default_results: 5,
      scrape_default_max_chars: 12000,
      document_parse_default_max_chars: 24000,
      document_parse_max_file_bytes: 41943040,
    },
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
      health: {
        status: 'valid',
        checked_at: '2026-05-31T10:00:00Z',
        credits_status: 'available',
      },
    },
  },
});

const mountComponent = (store, props = {}) => {
  vi.spyOn(store, 'fetch').mockResolvedValue();

  return shallowMount(Index, {
    props,
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
            'allowModelSelection',
            'showControls',
          ],
          template:
            '<section :data-feature-key="featureKey" :data-allow-model-selection="allowModelSelection"><span v-for="model in models || []" :key="model.id" data-test="model-id">{{ model.id }}</span><slot name="controls" /></section>',
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

  it('does not expose provider credentials in disabled workspace AI settings', () => {
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
        openrouter: {
          display_name: 'OpenRouter',
          source: 'global',
          health: { status: 'valid', checked_at: '2026-05-31T10:00:00Z' },
        },
        openai: { display_name: 'OpenAI', source: 'global' },
        anthropic: { display_name: 'Anthropic', source: 'global' },
        gemini: { display_name: 'Gemini', source: 'global' },
      },
    });

    const wrapper = mountComponent(store);

    expect(wrapper.text()).not.toContain('OpenRouter');
    expect(wrapper.text()).not.toContain(
      'CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.VALID'
    );
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

  it('does not expose service-model prompt controls in workspace settings', () => {
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
    ).toBe(false);
  });

  it('does not expose embedding model controls in workspace settings', () => {
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

    expect(embeddingBlock.exists()).toBe(false);
  });

  it('renders OpenRouter expenses and model analytics without budgets', () => {
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

    const wrapper = mountComponent(store, { section: 'usage' });

    expect(wrapper.find('[data-test="captain-usage-section"]').exists()).toBe(
      true
    );
    expect(wrapper.text()).toContain('CAPTAIN_SETTINGS.USAGE.TODAY_SPEND');
    expect(wrapper.get('base-settings-header-stub').attributes('title')).toBe(
      'CAPTAIN_SETTINGS.USAGE.TITLE'
    );
    expect(wrapper.text()).toContain('openai/gpt-5.4');
    expect(wrapper.text()).toContain('CAPTAIN_SETTINGS.USAGE.MODEL_COST_SHARE');
    expect(
      wrapper.get('[data-test="model-cost-share"]').attributes('style')
    ).toContain('width: 100%');
    expect(wrapper.text()).toContain('CAPTAIN_SETTINGS.USAGE.NO_RECENT_ERRORS');
    expect(wrapper.text()).not.toContain('CAPTAIN_SETTINGS.USAGE.BUDGET_TITLE');
  });

  it('does not render shared web access controls in account settings', () => {
    const store = useCaptainConfigStore();
    const payload = basePayload({
      audioModel: {
        id: 'openai/gpt-audio-mini',
        display_name: 'GPT Audio Mini',
        provider: 'openrouter',
        provider_configured: true,
        type: 'chat',
        capabilities: ['audio_input', 'text_output', 'transcription'],
      },
    });
    store.applyPayload(payload);
    const wrapper = mountComponent(store);

    expect(
      wrapper.find('[data-test="captain-web-access-section"]').exists()
    ).toBe(false);
    expect(wrapper.text()).not.toContain('CAPTAIN_SETTINGS.WEB_ACCESS.TITLE');
  });

  it('saves runtime guardrail modes for the AI Agent', async () => {
    const store = useCaptainConfigStore();
    const payload = basePayload({
      audioModel: {
        id: 'openai/gpt-audio-mini',
        display_name: 'GPT Audio Mini',
        provider: 'openrouter',
        provider_configured: true,
        type: 'chat',
        capabilities: ['audio_input', 'text_output', 'transcription'],
      },
    });
    payload.runtime.assistant_prompt_injection_guardrail = 'flag';
    payload.runtime.assistant_sensitive_info_guardrail = 'block';
    store.applyPayload(payload);
    const updateSpy = vi
      .spyOn(store, 'updatePreferences')
      .mockResolvedValue({ data: payload });

    const wrapper = mountComponent(store);
    wrapper.vm.runtimeGuardrailActions.assistant.sensitive_info = 'disabled';

    await wrapper.vm.handleRuntimeGuardrailChange(
      'assistant',
      'sensitive_info'
    );

    expect(updateSpy).toHaveBeenCalledWith({
      captain_runtime: {
        assistant_sensitive_info_guardrail: 'disabled',
      },
    });
  });
});
