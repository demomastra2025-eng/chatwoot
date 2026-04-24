import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

import AssistantBasicSettingsForm from './AssistantBasicSettingsForm.vue';
import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
} from '../toolAccessDefaults';

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
      feature_faq: false,
      feature_memory: false,
      feature_citation: false,
      tool_access: {
        [AGENT_TOOL_SCOPE]: {
          enabled: true,
          tool_ids: [
            FAQ_LOOKUP_TOOL_ID,
            HANDOFF_TOOL_ID,
            ADD_CONTACT_NOTE_TOOL_ID,
            ADD_PRIVATE_NOTE_TOOL_ID,
          ],
        },
      },
    });
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
