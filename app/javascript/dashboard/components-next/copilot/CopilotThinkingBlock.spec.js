import { describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';

import CopilotThinkingBlock from './CopilotThinkingBlock.vue';

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
  it('renders tool input and output inside native accordion details', () => {
    const wrapper = mountComponent({
      toolName: 'search_documentation',
      status: 'finish',
      input: '{\n  "query": "pricing"\n}',
      output: '{\n  "total": 2\n}',
    });

    const details = wrapper.findAll('details');

    expect(wrapper.text()).toContain('Completed search_documentation');
    expect(wrapper.text()).toContain('Input');
    expect(wrapper.text()).toContain('Output');
    expect(details).toHaveLength(2);
    expect(details[0].attributes('data-tool-trace-panel')).toBe('input');
    expect(details[1].attributes('data-tool-trace-panel')).toBe('output');
    expect(wrapper.text()).toContain('"query": "pricing"');
    expect(wrapper.text()).toContain('"total": 2');
  });
});
