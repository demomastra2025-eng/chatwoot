import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { useI18n } from 'vue-i18n';

import CaptainToolAccessAPI from 'dashboard/api/captain/toolAccess';
import ToolAccessSettings from './ToolAccessSettings.vue';

vi.mock('vue-i18n');
vi.mock('dashboard/api/captain/toolAccess', () => ({
  default: {
    get: vi.fn(),
  },
}));

const translations = {
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TITLE': 'Tool access',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.DESCRIPTION': 'Choose tools.',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.HINT': 'Hint',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.LOADING': 'Loading available tools...',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.ERROR': 'Could not load tools.',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.RETRY': 'Retry',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.EMPTY': 'No tools are available.',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.DISABLED_MESSAGE': 'Disabled',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.CUSTOM': 'Custom',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.REQUIRES_CONFIRMATION':
    'Needs confirmation',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.RISK_LEVELS.LOW': 'Low risk',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.RISK_LEVELS.MEDIUM':
    'Medium risk',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.RISK_LEVELS.HIGH': 'High risk',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.RISK_LEVELS.CUSTOM': 'Custom',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.SCOPES.AGENT.TITLE': 'Agent tools',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.SCOPES.AGENT.DESCRIPTION':
    'Agent description',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.SCOPES.ASSISTANT.TITLE':
    'Assistant tools',
  'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.SCOPES.ASSISTANT.DESCRIPTION':
    'Assistant description',
};

const mountComponent = props =>
  mount(ToolAccessSettings, {
    props: {
      assistantId: 12,
      modelValue: {},
      ...props,
    },
    global: {
      stubs: {
        Checkbox: {
          props: {
            modelValue: {
              type: Boolean,
              default: false,
            },
          },
          template: '<div class="checkbox-stub" />',
        },
        Switch: {
          props: {
            modelValue: {
              type: Boolean,
              default: false,
            },
          },
          template: '<div class="switch-stub" />',
        },
      },
    },
  });

describe('ToolAccessSettings', () => {
  beforeEach(() => {
    useI18n.mockReturnValue({
      t: vi.fn(key => translations[key] || key),
    });
  });

  it('renders both tool scopes and default selections from the API', async () => {
    CaptainToolAccessAPI.get.mockResolvedValue({
      data: [
        {
          id: 'faq_lookup',
          title: 'FAQ Lookup',
          group_name: 'Built-ins',
          scope_name: 'agent',
          description: 'Search docs',
          selected: true,
          risk_level: 'low',
        },
        {
          id: 'handoff',
          title: 'Handoff',
          group_name: 'Built-ins',
          scope_name: 'agent',
          description: 'Handoff to human',
          selected: true,
          risk_level: 'medium',
        },
        {
          id: 'search_documentation',
          title: 'Search documentation',
          group_name: 'Knowledge',
          scope_name: 'assistant',
          description: 'Search knowledge',
          selected: true,
          risk_level: 'low',
        },
        {
          id: 'custom_lookup_booking',
          title: 'Lookup booking',
          group_name: 'Custom tools',
          scope_name: 'assistant',
          description: 'Fetch external booking data',
          selected: false,
          custom: true,
          risk_level: 'custom',
          requires_confirmation: true,
        },
      ],
    });

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('Agent tools');
    expect(wrapper.text()).toContain('Assistant tools');
    expect(wrapper.text()).toContain('2 / 2');
    expect(wrapper.text()).toContain('1 / 2');
    expect(wrapper.text()).toContain('Low risk');
    expect(wrapper.text()).toContain('Custom');
    expect(wrapper.text()).toContain('Needs confirmation');
    expect(wrapper.emitted('update:modelValue')).toBeFalsy();
  });

  it('keeps explicit scope configuration visible even when no tools are returned', async () => {
    CaptainToolAccessAPI.get.mockResolvedValue({ data: [] });

    const wrapper = mountComponent({
      modelValue: {
        assistant: {
          enabled: false,
          tool_ids: [],
        },
      },
    });
    await flushPromises();

    expect(wrapper.text()).toContain('Assistant tools');
    expect(wrapper.text()).toContain('0 / 0');
  });

  it('shows a retry state when the tool catalog request fails', async () => {
    CaptainToolAccessAPI.get.mockRejectedValue(new Error('Request failed'));

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('Could not load tools.');
    expect(wrapper.text()).toContain('Retry');
  });
});
