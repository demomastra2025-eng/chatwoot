import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';

import AssistantBasicSettingsForm from './AssistantBasicSettingsForm.vue';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  ASSISTANT_TOOL_SCOPE,
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

const buildWrapper = props =>
  shallowMount(AssistantBasicSettingsForm, {
    props,
    global: {
      stubs: {
        Avatar: true,
        AssistantUsageModeSelector: true,
        Button: true,
        Editor: true,
        Input: true,
        Switch: true,
      },
    },
  });

describe('AssistantBasicSettingsForm', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    setActivePinia(createPinia());
    const captainConfigStore = useCaptainConfigStore();
    captainConfigStore.runtimeMetadata = {
      web_access: { configured: true },
    };
    vi.spyOn(captainConfigStore, 'fetch').mockResolvedValue();
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
      feature_web: false,
      feature_document_reading: false,
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

  it('persists web search, page reading, and document reading independently', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Поприветствуй клиента.',
        usage_mode: 'external_agent',
        config: { tool_access: {} },
      },
    });

    wrapper.vm.webSearchEnabled = true;
    wrapper.vm.webPageReadingEnabled = false;
    wrapper.vm.state.features.documentReading = true;
    await wrapper.vm.$nextTick();

    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.feature_document_reading).toBe(true);
    expect(payload.assistant.config.feature_web).toBe(false);
    expect(payload.assistant.config.tool_access.agent.tool_ids).toContain(
      WEB_SEARCH_TOOL_ID
    );
    expect(payload.assistant.config.tool_access.agent.tool_ids).not.toContain(
      WEB_SCRAPE_URL_TOOL_ID
    );
  });

  it('preserves internal assistant tool access from the instruction/tool-reference flow', async () => {
    const wrapper = buildWrapper({
      assistant: {
        id: 58,
        name: 'Мөлдір',
        description: 'Помогай сотрудникам.',
        usage_mode: 'internal_assistant',
        config: {
          feature_faq: false,
          feature_memory: false,
          feature_citation: true,
          tool_access: {
            [ASSISTANT_TOOL_SCOPE]: {
              enabled: true,
              tool_ids: ['get_workspace_profile', 'mcp__github__list_issues'],
            },
          },
        },
      },
    });

    const payload = await wrapper.vm.buildPayload();

    expect(payload.assistant.config.tool_access).toEqual({
      [ASSISTANT_TOOL_SCOPE]: {
        enabled: true,
        tool_ids: ['get_workspace_profile', 'mcp__github__list_issues'],
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
