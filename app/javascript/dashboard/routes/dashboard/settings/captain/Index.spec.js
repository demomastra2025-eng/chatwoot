import { flushPromises, shallowMount } from '@vue/test-utils';
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

const { storeDispatch } = vi.hoisted(() => ({
  storeDispatch: vi.fn(() => Promise.resolve()),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: storeDispatch }),
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
          props: {
            featureKey: String,
            title: String,
            description: String,
            models: Array,
            showControls: Boolean,
            allowModelSelection: { type: Boolean, default: true },
          },
          template:
            '<section :data-feature-key="featureKey" :data-allow-model-selection="String(allowModelSelection)"><span v-for="model in models || []" :key="model.id" data-test="model-id">{{ model.id }}</span><slot name="controls" /></section>',
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

    expect(wrapper.text()).toContain('OpenRouter');
    expect(wrapper.text()).toContain(
      'CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_LABEL'
    );
    expect(wrapper.text()).toContain(
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

  it('shows the models chosen by the platform without a picker and keeps the short list for the chat models', () => {
    const audioModel = {
      id: 'openai/gpt-4o-mini-transcribe',
      display_name: 'GPT-4o mini transcribe',
      provider: 'openrouter',
      provider_configured: true,
      type: 'transcription',
      capabilities: ['audio_input', 'transcription'],
    };
    const store = useCaptainConfigStore();
    store.applyPayload(basePayload({ audioModel }));

    const wrapper = mountComponent(store);
    const pickerFlag = featureKey =>
      wrapper
        .find(`[data-feature-key="${featureKey}"]`)
        .attributes('data-allow-model-selection');

    ['moderation', 'audio_transcription', 'help_center_search'].forEach(key => {
      expect(pickerFlag(key)).toBe('false');
    });
    ['editor', 'assistant', 'copilot'].forEach(key => {
      expect(pickerFlag(key)).toBe('true');
    });
    // image recognition and the label suggestion model have no card or picker at all
    expect(
      wrapper.find('[data-feature-key="image_recognition"]').exists()
    ).toBe(false);
    expect(wrapper.findComponent({ name: 'ModelDropdown' }).exists()).toBe(
      false
    );
  });

  it('renders OpenRouter usage and budget summary', () => {
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

    expect(wrapper.find('[data-test="captain-usage-section"]').exists()).toBe(
      true
    );
    expect(wrapper.text()).toContain('CAPTAIN_SETTINGS.USAGE.TODAY_SPEND');
    expect(wrapper.text()).toContain('openai/gpt-5.4');
    expect(wrapper.text()).toContain('CAPTAIN_SETTINGS.USAGE.NO_RECENT_ERRORS');
  });

  it('shows only the usage section on the «Расходы» page', () => {
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

    const usageWrapper = mountComponent(store, { section: 'usage' });

    expect(
      usageWrapper.find('[data-test="captain-usage-section"]').exists()
    ).toBe(true);
    expect(
      usageWrapper.find('[data-test="captain-web-access-section"]').exists()
    ).toBe(false);
    expect(
      usageWrapper.find('[data-test="captain-reliability-section"]').exists()
    ).toBe(false);
    expect(
      usageWrapper.find('[data-test="captain-text-improvement"]').exists()
    ).toBe(false);
    expect(usageWrapper.text()).not.toContain(
      'CAPTAIN_SETTINGS.PROVIDER_KEYS.SECRET_NOTE'
    );

    // The full AI settings page keeps every section, usage included.
    const settingsWrapper = mountComponent(store);
    expect(
      settingsWrapper.find('[data-test="captain-usage-section"]').exists()
    ).toBe(true);
    expect(
      settingsWrapper.find('[data-test="captain-web-access-section"]').exists()
    ).toBe(true);
    expect(
      settingsWrapper.find('[data-test="captain-text-improvement"]').exists()
    ).toBe(true);
  });

  it('renders web access controls and saves shared agent settings', async () => {
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
    const updateSpy = vi
      .spyOn(store, 'updatePreferences')
      .mockResolvedValue({ data: payload });

    const wrapper = mountComponent(store);

    expect(
      wrapper.find('[data-test="captain-web-access-section"]').exists()
    ).toBe(true);
    expect(wrapper.text()).toContain(
      'CAPTAIN_SETTINGS.WEB_ACCESS.SEARCH.TITLE'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN_SETTINGS.WEB_ACCESS.DOCUMENTS.TITLE'
    );
    expect(wrapper.text()).toContain('40 MB');
    expect(wrapper.text()).toContain(
      'CAPTAIN_SETTINGS.WEB_ACCESS.SCOPE_ASSISTANT'
    );

    await wrapper.vm.handleWebAccessToggle('web_search_enabled', true);

    expect(updateSpy).toHaveBeenCalledWith({
      captain_runtime: {
        web_search_enabled: true,
      },
    });
  });

  it('preserves zero budget limits and warning thresholds', () => {
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
    payload.usage.budgets.account_policy.warning_threshold = 0;
    payload.usage.budgets.account_policy.daily.limit = 0;
    payload.usage.budgets.account_policy.daily_budget = 0;
    store.applyPayload(payload);

    const wrapper = mountComponent(store);

    expect(wrapper.vm.budgetForm.warningThreshold).toBe(0);
    expect(wrapper.vm.budgetWindowCards[0].window.limit).toBe(0);
    expect(wrapper.text()).not.toContain('CAPTAIN_SETTINGS.USAGE.UNLIMITED');
  });

  it('saves account OpenRouter budget settings', async () => {
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
    const updateSpy = vi
      .spyOn(store, 'updatePreferences')
      .mockResolvedValue({ data: payload });

    const wrapper = mountComponent(store);
    wrapper.vm.budgetForm.active = true;
    wrapper.vm.budgetForm.hardStop = true;
    wrapper.vm.budgetForm.dailyBudget = 2.5;
    wrapper.vm.budgetForm.monthlyBudget = 50;
    wrapper.vm.budgetForm.warningThreshold = 75;

    await wrapper.vm.handleBudgetSave();

    expect(updateSpy).toHaveBeenCalledWith({
      captain_budget: {
        active: true,
        hard_stop: true,
        daily_budget: 2.5,
        monthly_budget: 50,
        warning_threshold: 0.75,
      },
    });
  });

  describe('text improvement switch', () => {
    const audioModel = {
      id: 'openai/gpt-audio-mini',
      display_name: 'GPT Audio Mini',
      provider: 'openrouter',
      provider_configured: true,
      type: 'chat',
      capabilities: ['audio_input', 'text_output', 'transcription'],
    };

    const findTextImprovementSwitch = wrapper =>
      wrapper
        .find('[data-test="captain-text-improvement"]')
        .findComponent({ name: 'Switch' });

    it('shows the switch on in the editor block when the account never changed it', () => {
      const store = useCaptainConfigStore();
      store.applyPayload(basePayload({ audioModel }));

      const wrapper = mountComponent(store);
      const row = wrapper.find('[data-test="captain-text-improvement"]');

      expect(row.exists()).toBe(true);
      expect(wrapper.find('[data-feature-key="editor"]').text()).toContain(
        'CAPTAIN_SETTINGS.FEATURES.TEXT_IMPROVEMENT.TITLE'
      );
      expect(findTextImprovementSwitch(wrapper).props('modelValue')).toBe(true);
    });

    it('shows the switch off when an admin switched it off', () => {
      const store = useCaptainConfigStore();
      const payload = basePayload({ audioModel });
      payload.features.editor = { models: [], enabled: false };
      store.applyPayload(payload);

      const wrapper = mountComponent(store);

      expect(findTextImprovementSwitch(wrapper).props('modelValue')).toBe(
        false
      );
    });

    // A legacy captain_features.editor=false from the old per-feature switch
    // must not decide; the new switch has its own key.
    it('saves captain_features.text_improvement and refreshes the account', async () => {
      const store = useCaptainConfigStore();
      const payload = basePayload({ audioModel });
      store.applyPayload(payload);
      storeDispatch.mockClear();
      const updateSpy = vi
        .spyOn(store, 'updatePreferences')
        .mockResolvedValue({ data: payload });

      const wrapper = mountComponent(store);
      await findTextImprovementSwitch(wrapper).vm.$emit('change', false);
      await flushPromises();

      expect(updateSpy).toHaveBeenCalledWith({
        captain_features: { text_improvement: false },
      });
      // Open reply boxes of this tab follow the switch without a reload.
      expect(storeDispatch).toHaveBeenCalledWith('accounts/get');
    });
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
