import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const { openDialogMock } = vi.hoisted(() => ({
  openDialogMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => {
      if (key === 'CAPTAIN.OBSERVABILITY.LOGS.MILLISECONDS') return 'мс';
      if (key === 'CAPTAIN.OBSERVABILITY.LOGS.SECONDS') return 'с';
      return key;
    },
    locale: { value: 'ru' },
  }),
}));

vi.mock('dashboard/components-next/dialog/Dialog.vue', () => ({
  default: defineComponent({
    setup(_props, { expose, slots }) {
      expose({ open: openDialogMock });
      return () => h('div', slots.default?.());
    },
  }),
}));

const { default: EventDetailsDialog } = await import(
  './EventDetailsDialog.vue'
);

const event = {
  id: 17,
  event_name: 'llm.tool.complete',
  feature: 'assistant',
  status: 'failed',
  reason: 'provider_unavailable',
  provider: 'openai',
  model: 'openai/gpt-5',
  tool_name: 'search_documentation',
  duration_ms: 1840,
  total_tokens: 1570,
  estimated_cost: 0.0042,
  created_at: '2026-08-26T10:00:00Z',
  error: true,
  details: {
    error_code: 'provider_unavailable',
    message: 'Synthetic provider error',
  },
};

describe('EventDetailsDialog', () => {
  beforeEach(() => openDialogMock.mockReset());

  it('shows duration, cost, error reason, and serialized event details', async () => {
    const wrapper = mount(EventDetailsDialog);

    wrapper.vm.open(event);
    await flushPromises();

    expect(openDialogMock).toHaveBeenCalledOnce();
    expect(wrapper.text()).toContain('failed');
    expect(wrapper.text()).toContain('1.84 с');
    expect(wrapper.text()).toContain('0,0042');
    expect(wrapper.text()).toContain('provider_unavailable');
    expect(wrapper.text()).toContain('Synthetic provider error');
  });
});
