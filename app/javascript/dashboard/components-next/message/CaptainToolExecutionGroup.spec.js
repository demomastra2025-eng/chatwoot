import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

const mocks = vi.hoisted(() => ({
  push: vi.fn(),
  route: {
    params: {
      accountId: '530',
      conversation_id: '5',
    },
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
  useRouter: () => ({
    push: mocks.push,
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

describe('CaptainToolExecutionGroup', () => {
  it('links visible tool details to the account observability trace page', async () => {
    const wrapper = mount(CaptainToolExecutionGroup, {
      props: {
        additionalAttributes: {
          captain_trace: {
            reasoning: 'Used CRM task tools.',
            trace_id: 'trace-1',
            session_id: 'session-1',
          },
        },
      },
    });

    expect(wrapper.find('[data-testid="thinking-group"]').exists()).toBe(true);
    expect(wrapper.find('i').classes()).toContain('i-lucide-file-text');
    await wrapper.find('button').trigger('click');

    expect(mocks.push).toHaveBeenCalledWith({
      name: 'captain_observability_index',
      params: { accountId: '530' },
      query: {
        tab: 'traces',
        trace_id: 'trace-1',
        session_id: 'session-1',
        conversation_display_id: '5',
      },
    });
  });

  it('can hide the trace page action', () => {
    const wrapper = mount(CaptainToolExecutionGroup, {
      props: {
        showOpenTraceAction: false,
        additionalAttributes: {
          captain_trace: {
            reasoning: 'Used CRM task tools.',
            trace_id: 'trace-1',
          },
        },
      },
    });

    expect(wrapper.find('[data-testid="thinking-group"]').exists()).toBe(true);
    expect(wrapper.find('button').exists()).toBe(false);
  });
});
