import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const dispatchMock = vi.fn();
const useAlertMock = vi.fn();
const routerPushMock = vi.fn();
const basicBuildPayloadMock = vi.fn();
const capabilitiesBuildPayloadMock = vi.fn();
const systemBuildPayloadMock = vi.fn();
const outcomeBuildPayloadMock = vi.fn();
const routingBuildPayloadMock = vi.fn();

const assistantRecord = {
  id: 57,
  name: 'Voice assistant',
  usage_mode: 'external_agent',
  config: {
    feature_faq: true,
    use_audio_transcriptions: true,
    handoff_message: 'old handoff',
    voice_settings: {
      provider: 'gemini-live',
      model: 'old-model',
      voice: 'old-voice',
    },
  },
};

const ButtonStub = defineComponent({
  name: 'NextButtonStub',
  props: {
    label: {
      type: String,
      default: '',
    },
  },
  emits: ['click'],
  setup(props, { emit }) {
    return () => h('button', { onClick: () => emit('click') }, props.label);
  },
});

const AssistantBasicSettingsFormStub = defineComponent({
  name: 'AssistantBasicSettingsForm',
  props: {
    showCoreSettings: {
      type: Boolean,
      default: true,
    },
  },
  setup(props, { expose }) {
    expose({
      buildPayload: props.showCoreSettings
        ? basicBuildPayloadMock
        : capabilitiesBuildPayloadMock,
    });
    return () => h('div', 'basic-form');
  },
});

const AssistantSystemSettingsFormStub = defineComponent({
  name: 'AssistantSystemSettingsForm',
  setup(_props, { expose }) {
    expose({ buildPayload: systemBuildPayloadMock });
    return () => h('div', 'system-form');
  },
});

const AssistantOutcomeSettingsFormStub = defineComponent({
  name: 'AssistantOutcomeSettingsForm',
  setup(_props, { expose }) {
    expose({ buildPayload: outcomeBuildPayloadMock });
    return () => h('div', 'outcome-form');
  },
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    params: { accountId: '6', assistantId: '57' },
  }),
  useRouter: () => ({ push: routerPushMock }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
    getters: {
      'captainAssistants/getRecord': () => assistantRecord,
    },
  }),
  useMapGetter: key => {
    if (key === 'captainAssistants/getUIFlags') {
      return ref({ fetchingItem: false });
    }
    if (key === 'captainAssistants/getRecords') {
      return ref([assistantRecord]);
    }
    return ref({});
  },
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: {
    deleteAvatar: vi.fn(),
    updateAvatar: vi.fn(),
  },
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    setup(_props, { slots }) {
      return () => h('div', slots.body?.());
    },
  }),
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: ButtonStub,
}));

vi.mock(
  'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue',
  () => ({
    default: defineComponent({ name: 'SettingsHeader', template: '<div />' }),
  })
);

vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantBasicSettingsForm.vue',
  () => ({ default: AssistantBasicSettingsFormStub })
);

vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantSystemSettingsForm.vue',
  () => ({ default: AssistantSystemSettingsFormStub })
);

vi.mock('../outcomes/Index.vue', () => ({
  default: AssistantOutcomeSettingsFormStub,
}));
vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantRoutingSettingsForm.vue',
  () => ({
    default: defineComponent({
      name: 'AssistantRoutingSettingsForm',
      setup(_props, { expose }) {
        expose({ buildPayload: routingBuildPayloadMock });
        return () => h('div', 'routing-form');
      },
    }),
  })
);

vi.mock(
  'dashboard/components-next/captain/pageComponents/DeleteDialog.vue',
  () => ({
    default: defineComponent({
      name: 'DeleteDialog',
      setup(_props, { expose }) {
        expose({ dialogRef: { open: vi.fn() } });
        return () => h('div', 'delete-dialog');
      },
    }),
  })
);

const { default: Settings } = await import('./Settings.vue');

const mountComponent = () => mount(Settings);

const clickUpdate = async wrapper => {
  const updateButton = wrapper
    .findAll('button')
    .find(button => button.text() === 'CAPTAIN.ASSISTANTS.FORM.UPDATE');

  await updateButton.trigger('click');
  await flushPromises();
};

describe('Captain assistant settings page', () => {
  beforeEach(() => {
    delete assistantRecord.config.legacy_scenario_migration;
    delete assistantRecord.config.safety_settings;
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue({});
    useAlertMock.mockReset();
    routerPushMock.mockReset();
    routingBuildPayloadMock.mockReset();
    routingBuildPayloadMock.mockReturnValue({
      assistant: {
        active: false,
        routing_description: 'Voice requests',
        handoff_agent_ids: [72, 73],
      },
    });

    basicBuildPayloadMock.mockReset();
    basicBuildPayloadMock.mockResolvedValue({
      assistant: {
        name: 'Voice assistant',
        description: 'Updated description',
        config: {
          temperature: 0.4,
          safety_settings: {
            moderation_enabled: true,
            prompt_injection_action: 'flag',
            sensitive_info_action: 'block',
          },
        },
      },
    });

    capabilitiesBuildPayloadMock.mockReset();
    capabilitiesBuildPayloadMock.mockResolvedValue({
      assistant: {
        config: {
          feature_faq: false,
          handoff_enabled: false,
          tool_access: { custom_tools: false },
          use_audio_transcriptions: false,
        },
      },
    });

    systemBuildPayloadMock.mockReset();
    systemBuildPayloadMock.mockResolvedValue({
      assistant: {
        config: {
          handoff_message: '',
          voice_settings: {
            provider: 'gemini-live',
            model: 'gemini-3.1-flash-live-preview',
            voice: 'sulafat',
            language: 'ru-KZ',
            system_prompt: '',
            first_message: '',
            transfer_message: '',
            max_duration_sec: 0,
            interruptions_enabled: false,
          },
        },
      },
    });

    outcomeBuildPayloadMock.mockReset();
    outcomeBuildPayloadMock.mockResolvedValue({
      assistant: {
        config: {
          auto_completion_enabled: true,
          outcome_reason_settings: {
            completion_reasons: [{ id: 'other', label: 'Other', active: true }],
            handoff_reasons: [{ id: 'other', label: 'Other', active: true }],
          },
        },
      },
    });
  });

  it('uses the assistant loaded by the route guard without another show request', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('basic-form');
    expect(dispatchMock).not.toHaveBeenCalledWith('captainAssistants/show', 57);
  });

  it('saves the general tab from its sections without changing the kind of the assistant', async () => {
    const wrapper = mountComponent();

    await clickUpdate(wrapper);

    const [action, payload] = dispatchMock.mock.calls.find(
      ([name]) => name === 'captainAssistants/update'
    );
    expect(action).toBe('captainAssistants/update');
    expect(payload).toEqual({
      id: 57,
      active: false,
      routing_description: 'Voice requests',
      handoff_agent_ids: [72, 73],
      name: 'Voice assistant',
      description: 'Updated description',
      config: expect.objectContaining({
        feature_faq: false,
        handoff_message: '',
        handoff_enabled: false,
        tool_access: { custom_tools: false },
        auto_completion_enabled: true,
        outcome_reason_settings: expect.objectContaining({
          completion_reasons: expect.any(Array),
          handoff_reasons: expect.any(Array),
        }),
        temperature: 0.4,
        safety_settings: {
          moderation_enabled: true,
          prompt_injection_action: 'flag',
          sensitive_info_action: 'block',
        },
        voice_settings: assistantRecord.config.voice_settings,
      }),
    });
    expect(payload).not.toHaveProperty('usage_mode');
  });

  it('replaces deleted custom rules with an explicit empty array only on the global save', async () => {
    const savedRule = {
      id: 'saved-rule',
      name: 'Contract changes',
      direction: 'input',
      instruction: 'If the customer asks to change contract terms.',
      action: 'handoff',
      enabled: true,
    };
    assistantRecord.config.safety_settings = {
      moderation_enabled: true,
      custom_rules: [savedRule],
    };
    basicBuildPayloadMock.mockResolvedValue({
      assistant: {
        name: assistantRecord.name,
        config: {
          safety_settings: { moderation_enabled: true, custom_rules: [] },
        },
      },
    });
    // A different form cannot reintroduce the original safety array.
    capabilitiesBuildPayloadMock.mockResolvedValue({
      assistant: {
        config: {
          feature_faq: false,
          safety_settings: { custom_rules: [savedRule] },
        },
      },
    });
    const wrapper = mountComponent();
    expect(dispatchMock).not.toHaveBeenCalled();
    await clickUpdate(wrapper);
    const writes = dispatchMock.mock.calls.filter(
      ([action]) => action === 'captainAssistants/update'
    );
    expect(writes).toHaveLength(1);
    expect(writes[0][1].config.safety_settings).toEqual({
      moderation_enabled: true,
      custom_rules: [],
    });
    expect(assistantRecord.config.safety_settings.custom_rules).toEqual([
      savedRule,
    ]);
  });

  it('preserves the exact priority order and public message from the rules draft', async () => {
    const rules = [
      {
        id: 'second-first',
        name: 'Contract terms',
        direction: 'input',
        instruction: 'If the customer asks to change contract terms.',
        action: 'handoff',
        enabled: false,
        message: 'A teammate will help with this request.',
      },
      {
        id: 'reply-check',
        name: 'Unsupported promise',
        direction: 'output',
        instruction: 'If the reply promises a result we cannot guarantee.',
        action: 'rewrite',
        enabled: true,
      },
    ];
    basicBuildPayloadMock.mockResolvedValue({
      assistant: {
        name: assistantRecord.name,
        config: { safety_settings: { custom_rules: rules } },
      },
    });
    const wrapper = mountComponent();
    expect(dispatchMock).not.toHaveBeenCalled();
    await clickUpdate(wrapper);
    expect(dispatchMock).toHaveBeenCalledWith(
      'captainAssistants/update',
      expect.objectContaining({
        config: expect.objectContaining({
          safety_settings: { custom_rules: rules },
          voice_settings: assistantRecord.config.voice_settings,
        }),
      })
    );
  });

  it('does not send a profile update when the rules draft fails validation', async () => {
    basicBuildPayloadMock.mockResolvedValue(null);
    const wrapper = mountComponent();
    await clickUpdate(wrapper);
    expect(dispatchMock).not.toHaveBeenCalled();
    expect(useAlertMock).not.toHaveBeenCalled();
  });

  it('persists disabling audio transcriptions for the assistant', async () => {
    const wrapper = mountComponent();

    await clickUpdate(wrapper);

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
      id: 57,
      active: false,
      routing_description: 'Voice requests',
      handoff_agent_ids: [72, 73],
      name: 'Voice assistant',
      description: 'Updated description',
      config: expect.objectContaining({
        use_audio_transcriptions: false,
      }),
    });
  });

  it('does not render a selector of the assistant kind', () => {
    const wrapper = mountComponent();

    expect(wrapper.html()).not.toContain('USAGE_MODE');
    expect(wrapper.text()).not.toContain('AssistantUsageModeSelector');
  });

  it('shows an AI agent with its outcomes and runtime sections', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('outcome-form');
    expect(wrapper.text()).toContain('system-form');
    expect(wrapper.text().match(/basic-form/g)).toHaveLength(2);
  });
  it('shows migration instruction review only when the converted agent has warnings', () => {
    const cleanWrapper = mountComponent();
    expect(
      cleanWrapper.find('[data-test="agent-migration-review"]').exists()
    ).toBe(false);
    assistantRecord.config.legacy_scenario_migration = {
      warnings: [
        {
          code: 'parent_reference',
          message: 'Review the copied tool references.',
        },
      ],
    };
    const wrapper = mountComponent();
    expect(
      wrapper.get('[data-test="agent-migration-review"]').text()
    ).toContain('CAPTAIN.ASSISTANTS.ROUTING.MIGRATION_REVIEW');
    expect(
      wrapper.get('[data-test="agent-migration-review"]').text()
    ).toContain('Review the copied tool references.');
  });

  it('saves voice agent settings from the dedicated voice tab', async () => {
    const wrapper = mountComponent();

    const voiceTab = wrapper
      .findAll('button')
      .find(
        button =>
          button.text() === 'CAPTAIN.ASSISTANTS.SETTINGS.TABS.VOICE_AGENT.LABEL'
      );

    await voiceTab.trigger('click');
    await clickUpdate(wrapper);

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
      id: 57,
      config: expect.objectContaining({
        feature_faq: true,
        handoff_message: 'old handoff',
        voice_settings: {
          provider: 'gemini-live',
          model: 'gemini-3.1-flash-live-preview',
          voice: 'sulafat',
          language: 'ru-KZ',
          system_prompt: '',
          first_message: '',
          transfer_message: '',
          max_duration_sec: 0,
          interruptions_enabled: false,
        },
      }),
    });
  });

  it('renders direct Pipecat preview in the dedicated voice tab', async () => {
    const wrapper = mountComponent();
    const voiceTab = wrapper
      .findAll('button')
      .find(
        button =>
          button.text() === 'CAPTAIN.ASSISTANTS.SETTINGS.TABS.VOICE_AGENT.LABEL'
      );

    expect(wrapper.find('[data-test-id="voice-agent-preview"]').exists()).toBe(
      false
    );
    await voiceTab.trigger('click');
    // The preview is an async component: its chunk loads outside the microtask queue.
    await vi.waitFor(() => {
      expect(
        wrapper.find('[data-test-id="voice-agent-preview"]').exists()
      ).toBe(true);
    });
    await flushPromises();
    expect(wrapper.text()).toContain('Gemini Live');
  });
});
