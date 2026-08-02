import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

import AssistantSystemSettingsForm from './AssistantSystemSettingsForm.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

const buildWrapper = props =>
  shallowMount(AssistantSystemSettingsForm, {
    props,
    global: {
      stubs: {
        Button: true,
        Editor: true,
        Input: true,
        SettingsInfoDialog: true,
        Switch: true,
      },
    },
  });

describe('AssistantSystemSettingsForm', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('builds a system settings payload without overwriting rules or tool config', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        config: {
          handoff_message: 'Передаю диалог коллеге.',
          resolution_message: 'Спасибо, вопрос закрыт.',
          temperature: 0.4,
          auto_reply_on_last_incoming: true,
          message_collapse_window_seconds: 3,
          history_message_limit: 15,
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
    });

    const payload = await wrapper.vm.buildPayload();
    await flushPromises();

    expect(payload.assistant.config).toEqual({
      handoff_message: 'Передаю диалог коллеге.',
      resolution_message: 'Спасибо, вопрос закрыт.',
      temperature: 0.4,
      auto_reply_on_last_incoming: true,
      message_collapse_window_seconds: 3,
      history_message_limit: 15,
      voice_settings: {
        provider: 'gemini-live',
        model: 'gemini-3.1-flash-live-preview',
        voice: 'sulafat',
        language: 'auto',
        thinking_level: 'minimal',
        context_window_compression_enabled: true,
        proactive_audio_enabled: false,
        system_prompt: '',
        voice_character_prompt: '',
        first_message: '',
        manager_handoff_mode: 'live_transfer',
        callback_message: '',
        transfer_message: '',
        transfer_failure_mode: 'continue',
        transfer_failure_message: '',
        silence_prompt_enabled: true,
        silence_prompt_after_ms: 5000,
        silence_prompt: '',
        second_silence_prompt_after_ms: 12000,
        second_silence_prompt: '',
        max_silence_ms: 25000,
        final_silence_message: '',
        end_call_on_silence_enabled: true,
        max_duration_sec: 0,
        interruptions_enabled: true,
        voice_activity_profile: 'balanced',
        affective_dialog_enabled: false,
      },
    });
  });

  it('renders voice settings accordion and emits edited voice settings', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        config: {
          voice_settings: {
            provider: 'gemini-live',
            model: 'gemini-2.5-flash-native-audio-preview-12-2025',
            voice: 'sulafat',
            language: 'ru-KZ',
            system_prompt: 'Говори коротко, без markdown и списков.',
            voice_character_prompt:
              'Тембр: тёплый наставник. Паузы короткие, без смеха.',
            first_message: 'Сәлеметсіз бе!',
            manager_handoff_mode: 'callback',
            callback_message: 'Менеджер сізге қайта қоңырау шалады.',
            transfer_message: 'Қазір операторға қосамын.',
            transfer_failure_mode: 'end_call',
            transfer_failure_message: 'Қосу мүмкін болмады.',
            silence_prompt_enabled: true,
            silence_prompt_after_ms: 6000,
            silence_prompt: 'Сіз желідесіз бе?',
            second_silence_prompt_after_ms: 14000,
            second_silence_prompt: 'Сұрағыңызды естуге дайынмын.',
            max_silence_ms: 30000,
            final_silence_message: 'Қоңырауды аяқтаймын.',
            end_call_on_silence_enabled: false,
            max_duration_sec: 450,
            interruptions_enabled: false,
            voice_activity_profile: 'noisy',
            proactive_audio_enabled: true,
            affective_dialog_enabled: true,
          },
        },
      },
    });

    expect(
      wrapper.find('[data-test-id="assistant-voice-settings"]').exists()
    ).toBe(true);
    expect(wrapper.text()).toContain(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TITLE'
    );
    expect(
      wrapper.find('[data-test-id="assistant-voice-system-prompt"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-test-id="assistant-voice-character-prompt"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-test-id="assistant-voice-manager-handoff"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-test-id="assistant-voice-silence-settings"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-test-id="assistant-gemini-proactive-audio"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-test-id="assistant-voice-activity-profile"]').exists()
    ).toBe(true);
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.ACTIVE_RUNTIME'
    );
    expect(
      wrapper
        .find('[data-test-id="assistant-gemini-affective-dialog"]')
        .exists()
    ).toBe(true);

    wrapper.vm.state.voiceSettings.voice = 'leda';
    wrapper.vm.state.voiceSettings.systemPrompt =
      'Отвечай максимум двумя короткими предложениями.';
    wrapper.vm.state.voiceSettings.voiceCharacterPrompt =
      'Тембр: спокойный ночной рассказчик. Интонация мягкая.';
    wrapper.vm.state.voiceSettings.firstMessage = 'Алло!';
    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.voice_settings).toEqual({
      provider: 'gemini-live',
      model: 'gemini-2.5-flash-native-audio-preview-12-2025',
      voice: 'leda',
      language: 'ru-KZ',
      thinking_level: 'minimal',
      context_window_compression_enabled: true,
      proactive_audio_enabled: true,
      system_prompt: 'Отвечай максимум двумя короткими предложениями.',
      voice_character_prompt:
        'Тембр: спокойный ночной рассказчик. Интонация мягкая.',
      first_message: 'Алло!',
      manager_handoff_mode: 'callback',
      callback_message: 'Менеджер сізге қайта қоңырау шалады.',
      transfer_message: 'Қазір операторға қосамын.',
      transfer_failure_mode: 'end_call',
      transfer_failure_message: 'Қосу мүмкін болмады.',
      silence_prompt_enabled: true,
      silence_prompt_after_ms: 6000,
      silence_prompt: 'Сіз желідесіз бе?',
      second_silence_prompt_after_ms: 14000,
      second_silence_prompt: 'Сұрағыңызды естуге дайынмын.',
      max_silence_ms: 30000,
      final_silence_message: 'Қоңырауды аяқтаймын.',
      end_call_on_silence_enabled: false,
      max_duration_sec: 450,
      interruptions_enabled: false,
      voice_activity_profile: 'noisy',
      affective_dialog_enabled: true,
    });

    wrapper.vm.state.voiceSettings.provider = 'openai-realtime';
    await wrapper.vm.$nextTick();
    expect(
      wrapper.find('[data-test-id="assistant-voice-activity-profile"]').exists()
    ).toBe(true);
  });

  it('normalizes unsupported voice activity profiles before display and save', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        config: {
          voice_settings: {
            voice_activity_profile: 'unsupported',
          },
        },
      },
    });

    expect(wrapper.vm.state.voiceSettings.voiceActivityProfile).toBe(
      'balanced'
    );

    wrapper.vm.state.voiceSettings.voiceActivityProfile = 'unsupported';
    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config.voice_settings.voice_activity_profile).toBe(
      'balanced'
    );
  });

  it('round-trips explicit zero silence thresholds', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        config: {
          voice_settings: {
            silence_prompt_after_ms: 0,
            second_silence_prompt_after_ms: 0,
            max_silence_ms: 0,
          },
        },
      },
    });

    expect(wrapper.vm.state.voiceSettings.silencePromptAfterSeconds).toBe(0);
    expect(wrapper.vm.state.voiceSettings.secondSilencePromptAfterSeconds).toBe(
      0
    );
    expect(wrapper.vm.state.voiceSettings.maxSilenceSeconds).toBe(0);

    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config.voice_settings).toEqual(
      expect.objectContaining({
        silence_prompt_after_ms: 0,
        second_silence_prompt_after_ms: 0,
        max_silence_ms: 0,
      })
    );
  });

  it('drops affective dialog for an unsupported Gemini model', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        config: {
          voice_settings: {
            provider: 'gemini-live',
            model: 'gemini-3.1-flash-live-preview',
            affective_dialog_enabled: true,
          },
        },
      },
    });

    expect(
      wrapper
        .find('[data-test-id="assistant-gemini-affective-dialog"]')
        .exists()
    ).toBe(false);
    expect(
      wrapper.find('[data-test-id="assistant-gemini-thinking-level"]').exists()
    ).toBe(true);
    expect(
      wrapper
        .find('[data-test-id="assistant-gemini-context-compression"]')
        .exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-test-id="assistant-gemini-proactive-audio"]').exists()
    ).toBe(true);

    wrapper.vm.state.voiceSettings.thinkingLevel = 'low';
    wrapper.vm.state.voiceSettings.contextWindowCompressionEnabled = false;
    wrapper.vm.state.voiceSettings.proactiveAudioEnabled = true;

    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.voice_settings).toEqual(
      expect.objectContaining({
        provider: 'gemini-live',
        model: 'gemini-3.1-flash-live-preview',
        language: 'auto',
        thinking_level: 'low',
        context_window_compression_enabled: false,
        proactive_audio_enabled: true,
        affective_dialog_enabled: false,
      })
    );
  });

  it('drops auto language when switching to legacy Gemini 2.0', async () => {
    const wrapper = buildWrapper({ assistant: { config: {} } });

    wrapper.vm.state.voiceSettings.proactiveAudioEnabled = true;
    wrapper.vm.state.voiceSettings.model = 'gemini-2.0-flash-live-001';
    await flushPromises();

    expect(wrapper.vm.state.voiceSettings.language).toBe('ru-KZ');
    expect(wrapper.vm.state.voiceSettings.proactiveAudioEnabled).toBe(false);
    expect(
      wrapper.find('[data-test-id="assistant-gemini-proactive-audio"]').exists()
    ).toBe(false);
    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config.voice_settings.language).toBe('ru-KZ');
    expect(
      payload.assistant.config.voice_settings.proactive_audio_enabled
    ).toBe(false);
  });

  it.each([
    ['openai-realtime', 'gpt-realtime-2', 'alloy'],
    ['elevenlabs', 'openai/gpt-5.4-mini', 'Xb7hH8MSUJpSbSDYk0k2'],
    ['cartesia', 'openai/gpt-5.4-mini', '71a7ad14-091c-4e8e-a314-022ece01c121'],
  ])(
    'applies compatible model and voice defaults for %s',
    async (provider, model, voice) => {
      const wrapper = buildWrapper({ assistant: { id: 58, config: {} } });

      wrapper.vm.state.voiceSettings.affectiveDialogEnabled = true;
      wrapper.vm.state.voiceSettings.proactiveAudioEnabled = true;
      wrapper.vm.updateVoiceProvider(provider);
      await wrapper.vm.$nextTick();
      const payload = await wrapper.vm.buildPayload();

      expect(payload.assistant.config.voice_settings).toEqual(
        expect.objectContaining({
          provider,
          model,
          voice,
          language: 'ru-KZ',
          proactive_audio_enabled: false,
          affective_dialog_enabled: false,
        })
      );
      expect(
        wrapper
          .find('[data-test-id="assistant-gemini-proactive-audio"]')
          .exists()
      ).toBe(false);
      expect(
        wrapper
          .find('[data-test-id="assistant-gemini-affective-dialog"]')
          .exists()
      ).toBe(false);
    }
  );

  it('requires a Fish voice id and persists either Fish STT variant', async () => {
    const wrapper = buildWrapper({ assistant: { id: 58, config: {} } });

    wrapper.vm.updateVoiceProvider('fish');
    await wrapper.vm.$nextTick();

    expect(
      wrapper.find('[data-test-id="assistant-fish-stt-provider"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-test-id="assistant-fish-voice-id"]').exists()
    ).toBe(true);
    expect(await wrapper.vm.buildPayload()).toBeNull();

    wrapper.vm.state.voiceSettings.voice = 'fish-voice-ref';
    wrapper.vm.state.voiceSettings.sttProvider = 'fish';
    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.voice_settings).toEqual(
      expect.objectContaining({
        provider: 'fish',
        stt_provider: 'fish',
        model: 'openai/gpt-5.4-mini',
        voice: 'fish-voice-ref',
        language: 'auto',
      })
    );
  });

  it('loads provider-specific defaults from a partial saved voice config', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        config: { voice_settings: { provider: 'openai-realtime' } },
      },
    });

    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.voice_settings).toEqual(
      expect.objectContaining({
        provider: 'openai-realtime',
        model: 'gpt-realtime-2',
        voice: 'alloy',
      })
    );
  });
});
