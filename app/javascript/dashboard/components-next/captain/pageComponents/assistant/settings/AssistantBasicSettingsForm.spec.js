import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

import AssistantBasicSettingsForm from './AssistantBasicSettingsForm.vue';
import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
  WEB_SCRAPE_URL_TOOL_ID,
  WEB_SEARCH_TOOL_ID,
} from '../toolAccessDefaults';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values = {}) =>
      key.replace(/\{(\w+)\}/g, (_, valueKey) => values[valueKey] ?? ''),
    te: () => false,
  }),
}));

const storeState = vi.hoisted(() => ({
  models: [],
  selected: null,
  runtimeMetadata: {},
}));

vi.mock('dashboard/store/captain/preferences', () => ({
  useCaptainConfigStore: () => ({
    getModelsForFeature: () => storeState.models,
    getSelectedModelForFeature: () => storeState.selected,
    runtimeMetadata: storeState.runtimeMetadata,
    fetch: vi.fn().mockResolvedValue(),
  }),
}));

const buildWrapper = props =>
  shallowMount(AssistantBasicSettingsForm, {
    props,
    global: {
      stubs: {
        Avatar: true,
        Button: true,
        Editor: true,
        Input: true,
        Select: true,
        Switch: true,
      },
    },
  });

describe('AssistantBasicSettingsForm', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    storeState.models = [];
    storeState.selected = null;
    storeState.runtimeMetadata = {};
  });

  describe('model choice', () => {
    const curatedModels = [
      { id: 'openai/gpt-6-luna', display_name: 'GPT-6 Luna' },
      { id: 'openai/gpt-5.6-luna', display_name: 'GPT-5.6 Luna' },
      { id: 'openai/gpt-5.4', display_name: 'GPT-5.4' },
      { id: 'openai/gpt-5.4-mini', display_name: 'GPT-5.4 mini' },
    ];
    const modelSelect = wrapper =>
      wrapper.findAllComponents({ name: 'Select' })[0];

    const platformDefaultOption = {
      value: '',
      label: 'CAPTAIN.ASSISTANTS.FORM.MODEL.PLATFORM_DEFAULT',
    };

    it('offers the platform default and only the short list curated by the platform', () => {
      storeState.models = curatedModels;
      const wrapper = buildWrapper({
        assistant: {
          id: 58,
          name: 'Мөлдір',
          usage_mode: 'external_agent',
          config: { model: 'openai/gpt-5.4' },
        },
      });

      expect(modelSelect(wrapper).props('options')).toEqual([
        platformDefaultOption,
        { value: 'openai/gpt-6-luna', label: 'GPT-6 Luna' },
        { value: 'openai/gpt-5.6-luna', label: 'GPT-5.6 Luna' },
        { value: 'openai/gpt-5.4', label: 'GPT-5.4' },
        { value: 'openai/gpt-5.4-mini', label: 'GPT-5.4 mini' },
      ]);
      // The model picker owns the curated list; safety controls have separate Selects.
      expect(wrapper.findAllComponents({ name: 'Select' })).toHaveLength(4);
    });

    it('removes provider branding from model option labels', () => {
      storeState.models = [
        {
          id: 'openai/gpt-5.4',
          display_name: 'GPT 5.4 via OpenRouter',
        },
      ];
      const wrapper = buildWrapper({
        assistant: { usage_mode: 'external_agent', config: {} },
      });

      expect(modelSelect(wrapper).props('options')[1].label).toBe(
        'GPT 5.4 via поставщик моделей'
      );
    });

    it('keeps the agent model outside the list selectable and marks it as the current one', async () => {
      storeState.models = curatedModels;
      const wrapper = buildWrapper({
        assistant: {
          id: 58,
          name: 'Мөлдір',
          description: 'Поприветствуй клиента.',
          usage_mode: 'external_agent',
          config: { model: 'legacy/old-model' },
        },
      });

      expect(modelSelect(wrapper).props('options')[0]).toEqual(
        platformDefaultOption
      );
      expect(modelSelect(wrapper).props('options')[1]).toEqual({
        value: 'legacy/old-model',
        label: 'legacy/old-model (CAPTAIN.ASSISTANTS.FORM.MODEL.CURRENT_MODEL)',
      });
      expect(modelSelect(wrapper).props('options')).toHaveLength(6);

      const payload = await wrapper.vm.buildPayload();
      expect(payload.assistant.config.model).toBe('legacy/old-model');
    });

    it('does not copy the workspace model into an agent that has none', async () => {
      storeState.models = curatedModels;
      storeState.selected = 'openai/gpt-6-luna';
      const wrapper = buildWrapper({
        assistant: {
          id: 58,
          name: 'Мөлдір',
          description: 'Поприветствуй клиента.',
          usage_mode: 'external_agent',
          config: {},
        },
      });
      await flushPromises();

      // the platform model is only named in the label of the empty option
      expect(modelSelect(wrapper).props('options')[0]).toEqual({
        value: '',
        label: 'CAPTAIN.ASSISTANTS.FORM.MODEL.PLATFORM_DEFAULT_WITH_MODEL',
      });
      const payload = await wrapper.vm.buildPayload();
      expect(payload.assistant.config.model).toBeNull();
    });

    it('lets the agent go back to the platform default by choosing the empty option', async () => {
      storeState.models = curatedModels;
      const wrapper = buildWrapper({
        assistant: {
          id: 58,
          name: 'Мөлдір',
          description: 'Поприветствуй клиента.',
          usage_mode: 'external_agent',
          config: { model: 'openai/gpt-6-luna' },
        },
      });
      await flushPromises();

      expect((await wrapper.vm.buildPayload()).assistant.config.model).toBe(
        'openai/gpt-6-luna'
      );
      modelSelect(wrapper).vm.$emit('update:modelValue', '');
      await wrapper.vm.$nextTick();

      const cleared = await wrapper.vm.buildPayload();
      expect(cleared.assistant.config.model).toBeNull();
    });

    it('does not copy a workspace model outside the list into an agent that has none', async () => {
      storeState.models = [
        ...curatedModels,
        {
          id: 'legacy/old-model',
          display_name: 'Old model',
          current_only: true,
        },
      ];
      storeState.selected = 'legacy/old-model';
      const wrapper = buildWrapper({
        assistant: {
          id: 58,
          name: 'Мөлдір',
          description: 'Поприветствуй клиента.',
          usage_mode: 'external_agent',
          config: {},
        },
      });
      await flushPromises();

      expect(modelSelect(wrapper).props('options')).toHaveLength(5);
      const payload = await wrapper.vm.buildPayload();
      expect(payload.assistant.config.model).toBeNull();
    });

    it('shows recognition capabilities as switches only', () => {
      const wrapper = buildWrapper({
        assistant: { usage_mode: 'external_agent', config: {} },
        showSubmitButton: false,
      });
      const text = wrapper.text();

      [
        'IMAGE_UNDERSTANDING',
        'DOCUMENT_READING',
        'WEB_SEARCH',
        'WEB_PAGE_READING',
        'USE_AUDIO_TRANSCRIPTIONS',
      ].forEach(key => {
        expect(text).toContain(`CAPTAIN.ASSISTANTS.FORM.FEATURES.${key}`);
      });
      expect(
        wrapper.findAllComponents({ name: 'Switch' }).length
      ).toBeGreaterThanOrEqual(8);
    });
  });

  it('includes capability tool access in profile payload so checkbox changes persist', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {
          feature_faq: false,
          feature_memory: false,
          feature_citation: false,
          tool_access: {},
          rules: [{ id: 'stay_within_scope', type: 'system' }],
        },
      },
    });

    wrapper.vm.faqLookupEnabled = true;
    wrapper.vm.notesEnabled = true;
    wrapper.vm.handoffToHumanEnabled = true;
    await wrapper.vm.$nextTick();

    const payload = await wrapper.vm.buildPayload();
    await flushPromises();

    expect(payload.assistant.config).toEqual({
      temperature: 1,
      model: null,
      message_collapse_window_seconds: 0,
      history_message_limit: 0,
      safety_settings: {
        moderation_enabled: null,
        prompt_injection_action: null,
        sensitive_info_action: null,
      },
      auto_reply_on_last_incoming: false,
      feature_faq: false,
      feature_memory: false,
      feature_citation: false,
      feature_web: true,
      feature_document_reading: true,
      feature_image_understanding: true,
      handoff_enabled: true,
      use_audio_transcriptions: true,
      tool_access: {
        [AGENT_TOOL_SCOPE]: {
          enabled: true,
          tool_ids: [
            FAQ_LOOKUP_TOOL_ID,
            HANDOFF_TOOL_ID,
            WEB_SEARCH_TOOL_ID,
            WEB_SCRAPE_URL_TOOL_ID,
            ADD_CONTACT_NOTE_TOOL_ID,
            ADD_PRIVATE_NOTE_TOOL_ID,
          ],
        },
      },
    });
  });

  it('offers every capability of an AI agent as a switch', () => {
    const wrapper = buildWrapper({
      assistant: { usage_mode: 'external_agent', config: {} },
      showSubmitButton: false,
    });
    const text = wrapper.text();

    [
      'AUTO_REPLY_ON_LAST_INCOMING.TITLE',
      'FEATURES.ALLOW_CONVERSATION_FAQS',
      'FEATURES.ALLOW_MEMORIES',
      'FEATURES.ALLOW_NOTES',
      'FEATURES.ALLOW_FAQ_LOOKUP',
      'FEATURES.ALLOW_HUMAN_HANDOFF',
    ].forEach(key => {
      expect(text).toContain(`CAPTAIN.ASSISTANTS.FORM.${key}`);
    });
  });

  it('renders no selector of the assistant kind', () => {
    storeState.models = [
      { id: 'openai/gpt-6-luna', display_name: 'GPT-6 Luna' },
    ];
    const wrapper = buildWrapper({
      assistant: { usage_mode: 'external_agent', config: {} },
    });
    const selects = wrapper.findAllComponents({ name: 'Select' });
    const modelOptions = selects[0].props('options');
    const safetyOptionValues = selects
      .slice(1)
      .flatMap(select => select.props('options').map(option => option.value));

    expect(wrapper.html()).not.toContain('USAGE_MODE');
    expect(selects).toHaveLength(4);
      expect(modelOptions.map(option => option.value)).toContain(
        'openai/gpt-6-luna'
      );
    expect(safetyOptionValues).not.toContain('external_agent');
    expect(safetyOptionValues).not.toContain('internal_assistant');
  });

  it('never sends the kind of the assistant when saving', async () => {
    const payload = await buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {},
      },
    }).vm.buildPayload();

    expect(payload.assistant).not.toHaveProperty('usage_mode');
  });

  it('keeps the model and the temperature apart from the capabilities', async () => {
    const assistant = {
      id: 58,
      name: 'Мөлдір',
      description: 'Поприветствуй клиента.',
      usage_mode: 'external_agent',
      config: { model: 'openai/gpt-5.4', temperature: 0.3 },
    };

    const core = buildWrapper({ assistant, showCapabilities: false });
    const corePayload = await core.vm.buildPayload();
    expect(corePayload.assistant.config.model).toBe('openai/gpt-5.4');
    expect(corePayload.assistant.config.temperature).toBe(0.3);
    expect(corePayload.assistant.config).toHaveProperty('safety_settings');

    const capabilities = buildWrapper({
      assistant,
      showCoreSettings: false,
      showIdentityFields: false,
    });
    const capabilitiesPayload = await capabilities.vm.buildPayload();
    expect(capabilitiesPayload.assistant).not.toHaveProperty('name');
    expect(capabilitiesPayload.assistant.config).not.toHaveProperty('model');
    expect(capabilitiesPayload.assistant.config).not.toHaveProperty(
      'temperature'
    );
    expect(capabilitiesPayload.assistant.config).not.toHaveProperty(
      'safety_settings'
    );
    expect(capabilitiesPayload.assistant.config).toHaveProperty('tool_access');
  });

  it('round-trips per-agent safety settings and leaves inherited controls unset', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {
          safety_settings: {
            moderation_enabled: true,
            prompt_injection_action: 'flag',
            sensitive_info_action: 'block',
          },
        },
      },
    });
    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.safety_settings).toEqual({
      moderation_enabled: true,
      prompt_injection_action: 'flag',
      sensitive_info_action: 'block',
    });

    const inheritedPayload = await buildWrapper({
      assistant: {
        id: 59,
        name: 'Талап',
        description: 'Keep workspace defaults.',
        usage_mode: 'external_agent',
        config: {},
      },
    }).vm.buildPayload();

    expect(inheritedPayload.assistant.config.safety_settings).toEqual({
      moderation_enabled: null,
      prompt_injection_action: null,
      sensitive_info_action: null,
    });
  });

  it('shows hand-over to a human as off when the server config turns it off', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {
          handoff_enabled: false,
          tool_access: {
            [AGENT_TOOL_SCOPE]: {
              enabled: true,
              tool_ids: [FAQ_LOOKUP_TOOL_ID, HANDOFF_TOOL_ID],
            },
          },
        },
      },
    });

    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.handoff_enabled).toBe(false);
    expect(
      payload.assistant.config.tool_access[AGENT_TOOL_SCOPE].tool_ids
    ).toEqual([FAQ_LOOKUP_TOOL_ID]);
    expect(wrapper.emitted('handoffCapabilityChange').at(-1)).toEqual([false]);
  });

  it('disables both web switches and shows availability beside each without a provider', () => {
    const wrapper = buildWrapper({
      assistant: {
        usage_mode: 'external_agent',
        config: {
          feature_document_reading: true,
          feature_image_understanding: true,
          tool_access: {
            [AGENT_TOOL_SCOPE]: {
              enabled: true,
              tool_ids: [WEB_SEARCH_TOOL_ID],
            },
          },
        },
      },
      showSubmitButton: false,
    });
    const switches = wrapper.findAllComponents({ name: 'Switch' });
    const disabled = switches.map(item => item.props('disabled'));

    expect(disabled.filter(Boolean)).toHaveLength(2);
    expect(
      wrapper.text().match(/FEATURES.WEB_PROVIDER_REQUIRED/g)
    ).toHaveLength(2);
  });
  it('persists an explicit empty agent scope when all default capability checkboxes are disabled', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {
          feature_faq: false,
          feature_memory: false,
          feature_citation: false,
          tool_access: {
            [AGENT_TOOL_SCOPE]: {
              enabled: true,
              tool_ids: [FAQ_LOOKUP_TOOL_ID, HANDOFF_TOOL_ID],
            },
          },
        },
      },
    });

    wrapper.vm.faqLookupEnabled = false;
    wrapper.vm.handoffToHumanEnabled = false;
    await wrapper.vm.$nextTick();

    const payload = await wrapper.vm.buildPayload();
    await flushPromises();

    expect(payload.assistant.config.tool_access).toEqual({
      [AGENT_TOOL_SCOPE]: {
        enabled: true,
        tool_ids: [],
      },
    });
  });

  it('preserves unrelated tool access entries when saving profile checkboxes', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {
          feature_faq: false,
          feature_memory: false,
          feature_citation: false,
          tool_access: {
            [AGENT_TOOL_SCOPE]: {
              enabled: true,
              tool_ids: [FAQ_LOOKUP_TOOL_ID, 'create_deal'],
            },
            assistant: {
              enabled: true,
              tool_ids: ['mcp__github__list_issues'],
            },
          },
        },
      },
    });

    wrapper.vm.handoffToHumanEnabled = true;
    await wrapper.vm.$nextTick();

    const payload = await wrapper.vm.buildPayload();
    await flushPromises();

    expect(payload.assistant.config.tool_access).toEqual({
      [AGENT_TOOL_SCOPE]: {
        enabled: true,
        tool_ids: [FAQ_LOOKUP_TOOL_ID, 'create_deal', HANDOFF_TOOL_ID],
      },
      assistant: {
        enabled: true,
        tool_ids: ['mcp__github__list_issues'],
      },
    });
  });

  it('persists web access when web tools are already enabled', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {
          feature_faq: false,
          feature_memory: false,
          feature_citation: false,
          feature_web: false,
          tool_access: {
            [AGENT_TOOL_SCOPE]: {
              enabled: true,
              tool_ids: [WEB_SEARCH_TOOL_ID, WEB_SCRAPE_URL_TOOL_ID],
            },
          },
        },
      },
    });

    const payload = await wrapper.vm.buildPayload();
    await flushPromises();

    expect(payload.assistant.config.feature_web).toBe(true);
  });

  it('persists the AI agent audio transcript capability', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: { use_audio_transcriptions: false },
      },
    });

    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.use_audio_transcriptions).toBe(false);
  });

  it('does not update the capability while workspace transcription is unavailable', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: { use_audio_transcriptions: true },
      },
      audioTranscriptionsAvailable: false,
    });

    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config).not.toHaveProperty(
      'use_audio_transcriptions'
    );
  });

  it('builds a prompt payload without unrelated config sections like rules or tool access', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Арманище',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {
          feature_faq: true,
          feature_memory: true,
          feature_citation: true,
          context_access: { contact: true },
          tool_access: {
            agent: {
              enabled: true,
              tool_ids: ['faq_lookup', 'handoff'],
            },
          },
          rules: [{ id: 'stay_within_scope', type: 'system' }],
        },
      },
      showNameField: false,
      showFeatureFlags: false,
    });

    const payload = await wrapper.vm.buildPayload();
    await flushPromises();

    expect(payload.assistant).toEqual({
      description: 'Поприветствуй клиента.',
    });
  });

  it('round-trips prompt newlines and whitespace without trimming saved instructions', async () => {
    const description =
      '\nUse the exact field names below.\n\n- Keep the heading.\n- Keep https://example.com/a-very-long-unbroken-path/unchanged\n';
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Арманище',
        description,
        usage_mode: 'external_agent',
        config: {},
      },
    });

    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.description).toBe(description);
  });

  it('passes prompt editor height, editability, and line-break settings to the shared editor', () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Арманище',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: {},
      },
      descriptionMinHeight: '19rem',
      descriptionInitialHeight: 304,
    });

    const editor = wrapper.findComponent({ name: 'Editor' });

    expect(editor.props('autoHeight')).toBe(true);
    expect(editor.props('overrideLineBreaks')).toBe(true);
    expect(editor.props('initialHeight')).toBe(304);
    expect(editor.props('minHeight')).toBe('19rem');
    expect(editor.props('disabled')).toBe(false);
  });
});
