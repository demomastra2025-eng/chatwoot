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
        language: 'ru-KZ',
        first_message: '',
        transfer_message: '',
        max_duration_sec: 0,
        interruptions_enabled: true,
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
            model: 'gemini-3.1-flash-live-preview',
            voice: 'sulafat',
            language: 'ru-KZ',
            first_message: 'Сәлеметсіз бе!',
            transfer_message: 'Қазір операторға қосамын.',
            max_duration_sec: 450,
            interruptions_enabled: false,
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

    wrapper.vm.state.voiceSettings.voice = 'leda';
    wrapper.vm.state.voiceSettings.firstMessage = 'Алло!';
    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.voice_settings).toEqual({
      provider: 'gemini-live',
      model: 'gemini-3.1-flash-live-preview',
      voice: 'leda',
      language: 'ru-KZ',
      first_message: 'Алло!',
      transfer_message: 'Қазір операторға қосамын.',
      max_duration_sec: 450,
      interruptions_enabled: false,
    });
  });
});
