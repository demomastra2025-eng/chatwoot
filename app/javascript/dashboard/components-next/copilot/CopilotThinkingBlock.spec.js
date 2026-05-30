import { describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';

import CopilotThinkingBlock from './CopilotThinkingBlock.vue';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key =>
      ({
        'CAPTAIN.COPILOT.TOOL_STATUS.RUNNING': 'Running',
        'CAPTAIN.COPILOT.TOOL_STATUS.COMPLETED': 'Completed',
        'CAPTAIN.COPILOT.TOOL_STATUS.FAILED': 'Failed',
        'CAPTAIN.COPILOT.TOOL_STATUS.SKIPPED': 'Skipped',
        'CAPTAIN.COPILOT.TOOL_TRACE.INPUT': 'Input',
        'CAPTAIN.COPILOT.TOOL_TRACE.OUTPUT': 'Output',
        'CAPTAIN.COPILOT.TOOL_TRACE.COPY_INPUT': 'Copy input',
        'CAPTAIN.COPILOT.TOOL_TRACE.COPY_OUTPUT': 'Copy output',
        'CAPTAIN.COPILOT.TOOL_TRACE.SCENARIO_HANDOFF':
          'Scenario handoff: Billing Agent',
        'CAPTAIN.COPILOT.TOOL_TRACE.COPY_SUCCESS': 'Copied',
        'CAPTAIN.COPILOT.TOOL_TRACE.COPY_ERROR': 'Unable to copy',
      })[key] || key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('shared/helpers/clipboard', () => ({
  copyTextToClipboard: vi.fn(() => Promise.resolve()),
}));

const mountComponent = props =>
  mount(CopilotThinkingBlock, {
    props: {
      content: 'Completed search_documentation',
      ...props,
    },
    global: {
      stubs: {
        Icon: true,
      },
    },
  });

describe('CopilotThinkingBlock', () => {
  it('renders tool input and output inside native accordion details', async () => {
    const wrapper = mountComponent({
      toolName: 'search_documentation',
      status: 'finish',
      input: '{\n  "query": "pricing"\n}',
      output: '{\n  "total": 2\n}',
    });

    const details = wrapper.findAll('details');

    expect(wrapper.text()).toContain('search_documentation');
    expect(wrapper.text()).toContain('Completed');
    expect(wrapper.text()).toContain('Input');
    expect(wrapper.text()).toContain('Output');
    expect(details).toHaveLength(2);
    expect(details[0].attributes('data-tool-trace-panel')).toBe('input');
    expect(details[1].attributes('data-tool-trace-panel')).toBe('output');
    expect(wrapper.text()).toContain('"query": "pricing"');
    expect(wrapper.text()).toContain('"total": 2');
    expect(wrapper.find('icon-stub').attributes('icon')).toBe(
      'i-lucide-wrench'
    );

    await wrapper.find('button[aria-label="Copy input"]').trigger('click');
    await flushPromises();

    expect(copyTextToClipboard).toHaveBeenCalledWith(
      '{\n  "query": "pricing"\n}'
    );
    expect(useAlert).toHaveBeenCalledWith('Copied');
  });

  it('renders scenario handoff tool calls with a readable title and route icon', () => {
    const wrapper = mountComponent({
      toolName: 'handoff_to_scenario_12_billing_agent',
      status: 'finish',
    });

    expect(wrapper.text()).toContain('Scenario handoff: Billing Agent');
    expect(wrapper.find('icon-stub').attributes('icon')).toBe('i-lucide-route');
  });

  it('renders reasoning text for non-tool thinking blocks', () => {
    const wrapper = mountComponent({
      content: 'Reasoning',
      reasoning: 'Matched the request to CRM deal 52 before updating it.',
    });

    expect(wrapper.text()).toContain('Reasoning');
    expect(wrapper.text()).toContain(
      'Matched the request to CRM deal 52 before updating it.'
    );
    expect(wrapper.find('icon-stub').attributes('icon')).toBe('i-lucide-brain');
  });
});
