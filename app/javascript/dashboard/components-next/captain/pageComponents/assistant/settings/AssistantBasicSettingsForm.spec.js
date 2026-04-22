import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

import AssistantBasicSettingsForm from './AssistantBasicSettingsForm.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

const buildWrapper = props =>
  shallowMount(AssistantBasicSettingsForm, {
    props,
    global: {
      stubs: {
        Avatar: true,
        AssistantUsageModeSelector: true,
        Button: true,
        Checkbox: true,
        Editor: true,
        Input: true,
      },
    },
  });

describe('AssistantBasicSettingsForm', () => {
  beforeEach(() => {
    vi.clearAllMocks();
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
      showUsageModeField: false,
      showFeatureFlags: false,
    });

    const payload = await wrapper.vm.buildPayload();
    await flushPromises();

    expect(payload.assistant).toEqual({
      description: 'Поприветствуй клиента.',
    });
  });
});
