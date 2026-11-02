import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import AssistantSystemSettingsForm from './AssistantSystemSettingsForm.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
const voiceOptions = [
  { value: 'sulafat', label: 'Sulafat' },
  { value: 'puck', label: 'Puck' },
];
const retired = [
  'provider',
  'stt_provider',
  'model',
  'delegation_model',
  'thinking_level',
  'api_version',
  'temperature',
  'max_output_tokens',
  'context_window_compression_enabled',
  'proactive_audio_enabled',
  'affective_dialog_enabled',
];
const buildWrapper = (voice = {}, props = {}) =>
  shallowMount(AssistantSystemSettingsForm, {
    props: {
      showConversationMessages: false,
      assistant: {
        id: 58,
        effective_settings: { voice_options: voiceOptions },
        config: { voice_settings: voice },
      },
      ...props,
    },
    global: {
      stubs: {
        Button: true,
        Editor: true,
        Input: true,
        Select: true,
        SettingsInfoDialog: true,
        Switch: true,
      },
    },
  });

describe('AssistantSystemSettingsForm platform voice profile', () => {
  beforeEach(() => vi.clearAllMocks());

  it('builds only a typed voice payload and never returns saved technical overrides or archives', async () => {
    const wrapper = buildWrapper({
      provider: 'openai-live',
      model: 'retired/model',
      delegation_model: 'retired/delegate',
      thinking_level: 'high',
      voice: 'marin',
      archive: { prompt: 'PRIVATE_ARCHIVE' },
      first_message: 'Business greeting',
      system_prompt: 'Platform instruction',
    });
    const config = (await wrapper.vm.buildPayload()).assistant.config;
    expect(Object.keys(config)).toEqual(['voice_settings']);
    expect(config.voice_settings).toEqual(
      expect.objectContaining({
        voice: 'sulafat',
        first_message: 'Business greeting',
        system_prompt: 'Platform instruction',
      })
    );
    retired.forEach(key =>
      expect(config.voice_settings).not.toHaveProperty(key)
    );
    expect(JSON.stringify(config)).not.toContain('PRIVATE_ARCHIVE');
    expect(wrapper.text()).not.toMatch(/Gemini|OpenAI|Cartesia|Fish Audio/);
    [
      'assistant-gemini-thinking-level',
      'assistant-gemini-context-compression',
      'assistant-gemini-proactive-audio',
      'assistant-gemini-affective-dialog',
      'assistant-fish-stt-provider',
      'assistant-fish-voice-id',
    ].forEach(id =>
      expect(wrapper.find(`[data-test-id="${id}"]`).exists()).toBe(false)
    );
  });

  it('uses the server voice options and retains selected voice, language, private instructions and business settings', async () => {
    const wrapper = buildWrapper({
      voice: 'puck',
      language: 'kk-KZ',
      input_language_priorities: ['kk-KZ', 'ru-KZ', 'en-US'],
      voice_character_prompt: 'Спокойный голос',
      first_message: 'Сәлеметсіз бе!',
      closing_message: 'Сау болыңыз!',
      manager_handoff_mode: 'callback',
      callback_message: 'Перезвоним',
      interruptions_enabled: false,
      max_duration_sec: 450,
    });
    expect(wrapper.vm.voiceVoiceOptions).toEqual(voiceOptions);
    expect(wrapper.vm.state.voiceSettings.voice).toBe('puck');
    wrapper.vm.state.voiceSettings.firstMessage = 'Алло!';
    const voice = (await wrapper.vm.buildPayload()).assistant.config
      .voice_settings;
    expect(voice).toEqual(
      expect.objectContaining({
        voice: 'puck',
        language: 'kk-KZ',
        input_language_priorities: ['kk-KZ', 'ru-KZ', 'en-US'],
        voice_character_prompt: 'Спокойный голос',
        first_message: 'Алло!',
        closing_message: 'Сау болыңыз!',
        manager_handoff_mode: 'callback',
        callback_message: 'Перезвоним',
        interruptions_enabled: false,
        max_duration_sec: 450,
      })
    );
  });

  it('round-trips false and zero business values and normalizes invalid activity profiles', async () => {
    const wrapper = buildWrapper({
      silence_prompt_after_ms: 0,
      second_silence_prompt_after_ms: 0,
      max_silence_ms: 0,
      silence_prompt_enabled: false,
      end_call_on_silence_enabled: false,
      voice_activity_profile: 'unsupported',
    });
    expect(
      (await wrapper.vm.buildPayload()).assistant.config.voice_settings
    ).toEqual(
      expect.objectContaining({
        silence_prompt_after_ms: 0,
        second_silence_prompt_after_ms: 0,
        max_silence_ms: 0,
        silence_prompt_enabled: false,
        end_call_on_silence_enabled: false,
        voice_activity_profile: 'balanced',
      })
    );
  });
});
