/* eslint-disable vue/one-component-per-file */
import { defineComponent, h, reactive, ref } from 'vue';
import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils';

const getMock = vi.fn();
const alertMock = vi.fn();
const replaceMock = vi.fn();
const dispatchMock = vi.fn();
const route = reactive({ query: {} });
const assistantRecords = ref([]);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      `${key}${params.count ?? ''}${params.name ? `:${params.name}` : ''}`,
    locale: { value: 'en' },
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => route,
  useRouter: () => ({ replace: replaceMock }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => alertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => assistantRecords,
  useStore: () => ({ dispatch: dispatchMock }),
}));

vi.mock('dashboard/api/captain/observability', () => ({
  default: { get: getMock },
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    props: { label: { type: String, default: '' } },
    emits: ['click'],
    setup(props, { emit }) {
      return () => h('button', { onClick: () => emit('click') }, props.label);
    },
  }),
}));

vi.mock('dashboard/components-next/select/Select.vue', () => ({
  default: defineComponent({
    props: {
      modelValue: { type: String, default: '' },
      options: { type: Array, default: () => [] },
    },
    emits: ['update:modelValue'],
    setup(props, { emit }) {
      return () =>
        h(
          'select',
          {
            value: props.modelValue,
            onChange: event => emit('update:modelValue', event.target.value),
          },
          props.options.map(option =>
            h('option', { value: option.value }, option.label)
          )
        );
    },
  }),
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    props: { isEmpty: Boolean },
    setup(props, { slots }) {
      return () =>
        h('main', [
          slots.search?.(),
          props.isEmpty ? slots.emptyState?.() : slots.body?.(),
        ]);
    },
  }),
}));

vi.mock('dashboard/components/ui/DatePicker/DatePicker.vue', () => ({
  default: defineComponent({
    props: {
      calendarOnly: Boolean,
      compact: Boolean,
      forceOpen: Boolean,
      hideTrigger: Boolean,
    },
    emits: ['dateRangeChanged'],
    setup(props, { emit }) {
      return () =>
        h(
          'button',
          {
            'data-test-id': 'custom-range-calendar',
            'data-calendar-only': String(props.calendarOnly),
            'data-compact': String(props.compact),
            'data-force-open': String(props.forceOpen),
            'data-hide-trigger': String(props.hideTrigger),
            onClick: () =>
              emit('dateRangeChanged', [
                new Date('2026-08-01T00:00:00Z'),
                new Date('2026-08-15T23:59:59Z'),
                'custom',
              ]),
          },
          'calendar'
        );
    },
  }),
}));

vi.mock('./EventDetailsDialog.vue', () => ({
  default: defineComponent({
    setup(_props, { expose }) {
      expose({ open: vi.fn() });
      return () => h('div');
    },
  }),
}));

const { default: ObservabilityIndex } = await import('./Index.vue');

const event = {
  id: 17,
  event_name: 'llm.chat.complete',
  model: 'openai/gpt-5',
  prompt_tokens: 1250,
  completion_tokens: 320,
  estimated_cost: 0.0042,
  duration_ms: 1840,
  created_at: '2026-08-26T10:00:00Z',
};

const response = {
  data: {
    payload: [event],
    time_series: {
      bucket: 'hour',
      points: [
        { timestamp: 1_777_200_000, request_count: 2 },
        { timestamp: 1_777_203_600, request_count: 5 },
      ],
    },
    meta: { count: 1, current_page: 1, per_page: 25 },
  },
};

const agentFilterChip = wrapper =>
  wrapper.find('[data-test-id="logs-agent-filter"]');

// Every page watches the shared route mock. Pages left mounted by earlier tests
// would refetch whenever a later test changes route.query.
enableAutoUnmount(afterEach);

describe('AI Agent logs', () => {
  beforeEach(() => {
    getMock.mockReset();
    getMock.mockResolvedValue(response);
    alertMock.mockReset();
    replaceMock.mockReset();
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue([]);
    route.query = {};
    assistantRecords.value = [];
  });

  it('requests completed AI Agent calls for the selected time range', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(getMock).toHaveBeenCalledWith(
      expect.objectContaining({
        feature: 'assistant',
        event_name: 'llm.chat.complete',
        page: 1,
        per_page: 25,
        since: expect.any(String),
        until: expect.any(String),
      })
    );
    const params = getMock.mock.calls[0][0];
    expect(Number(params.until) - Number(params.since)).toBeGreaterThanOrEqual(
      30 * 24 * 60 * 60 - 2
    );
    expect(params).not.toHaveProperty('assistant_id');
    expect(agentFilterChip(wrapper).exists()).toBe(false);
    expect(dispatchMock).not.toHaveBeenCalled();
  });

  describe('filter by agent («Логи агента»)', () => {
    it('requests only the calls of the agent from the link and names it', async () => {
      route.query = { assistant_id: '7' };
      assistantRecords.value = [{ id: 7, name: 'Sofia' }];

      const wrapper = mount(ObservabilityIndex);
      await flushPromises();

      expect(getMock).toHaveBeenCalledWith(
        expect.objectContaining({ assistant_id: '7', page: 1 })
      );
      expect(agentFilterChip(wrapper).text()).toContain(
        'CAPTAIN.NAV.LOGS_AGENT_FILTER:Sofia'
      );
      expect(dispatchMock).not.toHaveBeenCalled();
    });

    it('shows the agent id and loads the agents when they are not loaded yet', async () => {
      route.query = { assistant_id: '7' };

      const wrapper = mount(ObservabilityIndex);
      await flushPromises();

      expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/get');
      expect(agentFilterChip(wrapper).text()).toContain(
        'CAPTAIN.NAV.LOGS_AGENT_FILTER:#7'
      );

      assistantRecords.value = [{ id: 7, name: 'Sofia' }];
      await flushPromises();

      expect(agentFilterChip(wrapper).text()).toContain(
        'CAPTAIN.NAV.LOGS_AGENT_FILTER:Sofia'
      );
    });

    it('removes only the agent from the link when the chip is cleared', async () => {
      route.query = { assistant_id: '7', source: 'agent_page' };
      assistantRecords.value = [{ id: 7, name: 'Sofia' }];

      const wrapper = mount(ObservabilityIndex);
      await flushPromises();

      await wrapper
        .get('button[aria-label="CAPTAIN.NAV.LOGS_AGENT_FILTER_CLEAR"]')
        .trigger('click');

      expect(replaceMock).toHaveBeenCalledWith({
        query: { source: 'agent_page' },
      });
    });

    it('reloads all calls once the agent filter leaves the link', async () => {
      route.query = { assistant_id: '7' };
      assistantRecords.value = [{ id: 7, name: 'Sofia' }];

      const wrapper = mount(ObservabilityIndex);
      await flushPromises();
      expect(getMock).toHaveBeenCalledTimes(1);

      route.query = {};
      await flushPromises();

      expect(getMock).toHaveBeenCalledTimes(2);
      expect(getMock.mock.calls[1][0]).not.toHaveProperty('assistant_id');
      expect(getMock.mock.calls[1][0].page).toBe(1);
      expect(agentFilterChip(wrapper).exists()).toBe(false);
    });

    it('ignores an agent id that is not a number', async () => {
      route.query = { assistant_id: 'abc' };

      const wrapper = mount(ObservabilityIndex);
      await flushPromises();

      expect(getMock.mock.calls[0][0]).not.toHaveProperty('assistant_id');
      expect(agentFilterChip(wrapper).exists()).toBe(false);
      expect(dispatchMock).not.toHaveBeenCalled();
    });
  });

  it('renders the request timeline and required table columns', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CAPTAIN.OBSERVABILITY.LOGS.TIMELINE_TITLE'
    );
    expect(wrapper.findAll('table tbody tr')).toHaveLength(1);
    expect(wrapper.text()).toContain('openai/gpt-5');
    expect(wrapper.text()).toContain('1,250');
    expect(wrapper.text()).toContain('320');
    expect(wrapper.text()).toContain('$0.004200');
    expect(wrapper.text()).toContain('1.84');
    expect(wrapper.findAll('table thead th')).toHaveLength(6);
  });

  it('reloads the timeline when the time range changes', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper.find('select').setValue('7d');
    await flushPromises();

    expect(getMock).toHaveBeenCalledTimes(2);
  });

  it('applies a custom date range from the visual calendar', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper.find('select').setValue('custom');
    await flushPromises();
    expect(getMock).toHaveBeenCalledTimes(1);

    const calendar = wrapper.get('[data-test-id="custom-range-calendar"]');
    expect(calendar.attributes('data-force-open')).toBe('true');
    expect(calendar.attributes('data-calendar-only')).toBe('true');
    expect(calendar.attributes('data-compact')).toBe('true');
    expect(calendar.attributes('data-hide-trigger')).toBe('true');

    await calendar.trigger('click');
    await flushPromises();

    expect(getMock).toHaveBeenCalledTimes(2);
    expect(getMock).toHaveBeenLastCalledWith(
      expect.objectContaining({
        since: String(
          Math.floor(new Date('2026-08-01T00:00:00Z').getTime() / 1000)
        ),
        until: String(
          Math.floor(new Date('2026-08-15T23:59:59Z').getTime() / 1000)
        ),
      })
    );
  });
});
