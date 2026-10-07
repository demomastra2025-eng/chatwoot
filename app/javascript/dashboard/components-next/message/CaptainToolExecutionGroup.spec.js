import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/components-next/copilot/CopilotThinkingGroup.vue', () => ({
  default: {
    name: 'CopilotThinkingGroup',
    props: {
      messages: { type: Array, required: true },
      defaultCollapsed: { type: Boolean, default: false },
    },
    template:
      '<div data-testid="thinking-group">{{ messages.length }}<slot name="headerAction" /></div>',
  },
}));

const { default: CaptainToolExecutionGroup } = await import(
  './CaptainToolExecutionGroup.vue'
);

const additionalAttributes = {
  captain_trace: {
    reasoning: 'Used CRM task tools.',
    trace_id: 'trace-1',
    session_id: 'session-1',
  },
};

describe('CaptainToolExecutionGroup', () => {
  it('renders the collapsed tool details of the reply', () => {
    const wrapper = mount(CaptainToolExecutionGroup, {
      props: { additionalAttributes },
    });

    expect(wrapper.find('[data-testid="thinking-group"]').text()).toBe('1');
  });

  it('has no link to the logs page, which only administrators can open and which ignores trace filters', () => {
    const wrapper = mount(CaptainToolExecutionGroup, {
      props: { additionalAttributes },
    });

    expect(wrapper.find('button').exists()).toBe(false);
    expect(wrapper.find('[data-testid="captain-trace-logs"]').exists()).toBe(
      false
    );
  });
});
