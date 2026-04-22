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
    });
  });
});
