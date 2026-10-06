/* eslint-disable vue/one-component-per-file */
import { defineComponent, h, reactive, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const { getMock, alertMock, routeQuery, openEventMock } = vi.hoisted(() => ({
  getMock: vi.fn(),
  alertMock: vi.fn(),
  routeQuery: { value: {} },
  openEventMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) => (params.count ? key + params.count : key),
    locale: { value: 'en' },
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    get query() {
      return routeQuery.value;
    },
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => alertMock(...args),
}));

vi.mock('dashboard/api/captain/observability', () => ({
  default: { get: getMock },
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    props: {
      label: { type: String, default: '' },
      disabled: Boolean,
    },
    emits: ['click'],
    setup(props, { emit }) {
      return () =>
        h(
          'button',
          {
            disabled: props.disabled,
            onClick: () => emit('click'),
          },
          props.label
        );
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
    props: {
      isEmpty: Boolean,
      totalCount: { type: Number, default: 0 },
    },
    emits: ['update:current-page'],
    setup(props, { slots, emit }) {
      return () =>
        h('main', { 'data-total-count': String(props.totalCount) }, [
          slots.search?.(),
          props.isEmpty ? slots.emptyState?.() : slots.body?.(),
          h(
            'button',
            {
              type: 'button',
              'data-testid': 'next-page',
              onClick: () => emit('update:current-page', 2),
            },
            'next'
          ),
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
      const isOpen = ref(props.forceOpen);
      const rangeIndex = ref(0);
      const rangeStart = ref(null);
      const ranges = [
        [new Date('2026-08-01T00:00:00Z'), new Date('2026-08-15T23:59:59Z')],
        [new Date('2026-09-01T00:00:00Z'), new Date('2026-09-10T23:59:59Z')],
      ];

      return () =>
        h(
          'div',
          {
            'data-calendar-only': String(props.calendarOnly),
            'data-compact': String(props.compact),
            'data-force-open': String(props.forceOpen),
            'data-hide-trigger': String(props.hideTrigger),
          },
          [
            props.hideTrigger
              ? null
              : h(
                  'button',
                  {
                    'data-test-id': 'custom-range-calendar-trigger',
                    onClick: () => {
                      isOpen.value = !isOpen.value;
                    },
                  },
                  'change range'
                ),
            isOpen.value
              ? h('div', { 'data-test-id': 'custom-range-calendar' }, [
                  h(
                    'button',
                    {
                      'data-test-id': 'select-custom-start',
                      onClick: () => {
                        rangeStart.value = ranges[rangeIndex.value][0];
                      },
                    },
                    'start'
                  ),
                  h(
                    'button',
                    {
                      'data-test-id': 'select-custom-end',
                      onClick: () => {
                        emit('dateRangeChanged', [
                          rangeStart.value,
                          ranges[rangeIndex.value][1],
                          'custom',
                        ]);
                        rangeIndex.value += 1;
                        isOpen.value = false;
                      },
                    },
                    'end'
                  ),
                ])
              : null,
          ]
        );
    },
  }),
}));

vi.mock('./EventDetailsDialog.vue', () => ({
  default: defineComponent({
    setup(_props, { expose }) {
      expose({ open: openEventMock });
      return () => h('div');
    },
  }),
}));

const { default: ObservabilityIndex } = await import('./Index.vue');

const event = {
  id: 17,
  event_name: 'llm.chat.complete',
  feature: 'captain_agent',
  status: 'failed',
  reason: 'provider_unavailable',
  provider: 'openai',
  assistant_id: 42,
  conversation_display_id: 501,
  model: 'openai/gpt-5',
  prompt_tokens: 1250,
  completion_tokens: 320,
  total_tokens: 1570,
  estimated_cost: 0.0042,
  duration_ms: 1840,
  error: true,
  details: {
    error_code: 'provider_unavailable',
    message: 'Synthetic provider error',
  },
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

const buttonByLabel = (wrapper, label) =>
  wrapper.findAll('button').find(button => button.text() === label);

describe('AI Agent logs', () => {
  beforeEach(() => {
    getMock.mockReset();
    getMock.mockResolvedValue(response);
    alertMock.mockReset();
    openEventMock.mockReset();
    routeQuery.value = {};
  });

  it('requests Captain agent completions in both supported feature families', async () => {
    mount(ObservabilityIndex);
    await flushPromises();

    expect(getMock).toHaveBeenCalledWith(
      expect.objectContaining({
        features: ['assistant', 'captain_agent'],
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
  });

  it('renders the timeline, event context, and opens event details', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CAPTAIN.OBSERVABILITY.LOGS.TIMELINE_TITLE'
    );
    expect(wrapper.findAll('table tbody tr')).toHaveLength(1);
    expect(wrapper.text()).toContain('llm.chat.complete');
    expect(wrapper.text()).toContain('42');
    expect(wrapper.text()).toContain('501');
    expect(wrapper.text()).toContain('openai/gpt-5');
    expect(wrapper.text()).toContain('1,250');
    expect(wrapper.text()).toContain('320');
    expect(wrapper.text()).toContain('$0.004200');
    expect(wrapper.text()).toContain('1.84');
    expect(wrapper.findAll('table thead th')).toHaveLength(9);

    await wrapper.get('table tbody tr').trigger('click');
    expect(openEventMock).toHaveBeenCalledWith(event);
  });

  it('keeps unknown metrics distinct from explicit zero values', async () => {
    const unknownMetrics = {
      ...event,
      id: 18,
      prompt_tokens: null,
      completion_tokens: null,
      estimated_cost: null,
      duration_ms: null,
    };
    const zeroMetrics = {
      ...event,
      id: 19,
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated_cost: 0,
      duration_ms: 0,
    };
    getMock.mockResolvedValue({
      data: {
        ...response.data,
        payload: [unknownMetrics, zeroMetrics],
        meta: { count: 2, current_page: 1, per_page: 25 },
      },
    });

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    const rows = wrapper.findAll('table tbody tr');
    expect(rows).toHaveLength(2);
    const unknownCells = rows[0].findAll('td');
    expect(unknownCells[5].text()).toBe('—');
    expect(unknownCells[6].text()).toBe('—');
    expect(unknownCells[7].text()).toBe('—');
    expect(unknownCells[8].text()).toBe('—');

    const zeroCells = rows[1].findAll('td');
    expect(zeroCells[5].text()).toBe('0');
    expect(zeroCells[6].text()).toBe('0');
    expect(zeroCells[7].text()).toBe('$0.000000');
    expect(zeroCells[8].text()).toBe(
      '0 CAPTAIN.OBSERVABILITY.LOGS.MILLISECONDS'
    );
  });

  it('counts chat requests from the chart while pagination keeps all trace events', async () => {
    const traceEvents = Array.from({ length: 9 }, (_, index) => ({
      ...event,
      id: index + 1,
      event_name: index === 0 ? 'llm.chat.complete' : 'llm.tool.complete',
    }));
    getMock.mockResolvedValue({
      data: {
        payload: traceEvents,
        time_series: {
          bucket: 'hour',
          points: [{ timestamp: 1_777_200_000, request_count: 1 }],
        },
        meta: { count: 9, current_page: 1, per_page: 25 },
      },
    });
    routeQuery.value = { trace_id: 'mixed-trace' };

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CAPTAIN.OBSERVABILITY.LOGS.TOTAL_REQUESTS1'
    );
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.OBSERVABILITY.LOGS.TOTAL_REQUESTS9'
    );
    expect(wrapper.get('main').attributes('data-total-count')).toBe('9');
    expect(wrapper.findAll('table tbody tr')).toHaveLength(9);
  });

  it('opens the requested full trace without adding completion-only filters', async () => {
    routeQuery.value = {
      tab: 'traces',
      trace_id: 'trace-1',
      session_id: 'session-1',
      conversation_display_id: '501',
      copilot_thread_id: 'thread-1',
    };

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(getMock).toHaveBeenCalledWith(
      expect.objectContaining({
        trace_id: 'trace-1',
        session_id: 'session-1',
        conversation_display_id: '501',
        copilot_thread_id: 'thread-1',
        page: 1,
        per_page: 25,
      })
    );
    const params = getMock.mock.calls[0][0];
    expect(params).not.toHaveProperty('features');
    expect(params).not.toHaveProperty('feature');
    expect(params).not.toHaveProperty('event_name');
    expect(params).not.toHaveProperty('tab');
    expect(params).not.toHaveProperty('since');
    expect(params).not.toHaveProperty('until');
    expect(wrapper.find('select').element.value).toBe('account_default');
  });

  it('uses account lookback for trace links and lets a manual preset override it', async () => {
    const olderTraceEvent = {
      ...event,
      created_at: new Date(Date.now() - 45 * 24 * 60 * 60 * 1000).toISOString(),
    };
    getMock.mockResolvedValue({
      data: {
        ...response.data,
        payload: [olderTraceEvent],
        preferences: { default_lookback_days: 90 },
      },
    });
    routeQuery.value = { trace_id: 'trace-from-45-days-ago' };

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    const traceParams = getMock.mock.calls[0][0];
    expect(traceParams.trace_id).toBe('trace-from-45-days-ago');
    expect(traceParams).not.toHaveProperty('since');
    expect(traceParams).not.toHaveProperty('until');
    expect(wrapper.findAll('table tbody tr')).toHaveLength(1);
    expect(wrapper.find('select').element.value).toBe('account_default');

    await wrapper.find('select').setValue('7d');
    await flushPromises();

    const manualParams = getMock.mock.calls.at(-1)[0];
    expect(manualParams).toEqual(
      expect.objectContaining({
        trace_id: 'trace-from-45-days-ago',
        since: expect.any(String),
        until: expect.any(String),
      })
    );
    expect(
      Number(manualParams.until) - Number(manualParams.since)
    ).toBeGreaterThanOrEqual(7 * 24 * 60 * 60 - 2);
    expect(wrapper.find('select').element.value).toBe('7d');
  });

  it('resets a manual preset when a new shared trace link omits dates', async () => {
    routeQuery.value = reactive({});
    const olderTraceResponse = {
      data: {
        ...response.data,
        payload: [
          {
            ...event,
            created_at: new Date(
              Date.now() - 45 * 24 * 60 * 60 * 1000
            ).toISOString(),
          },
        ],
        preferences: { default_lookback_days: 90 },
      },
    };
    getMock.mockImplementation(params =>
      Promise.resolve(params.trace_id ? olderTraceResponse : response)
    );
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(getMock.mock.calls[0][0]).toHaveProperty('since');
    await wrapper.find('select').setValue('15m');
    await flushPromises();
    const manualParams = getMock.mock.calls.at(-1)[0];
    expect(
      Number(manualParams.until) - Number(manualParams.since)
    ).toBeLessThanOrEqual(15 * 60 + 2);

    routeQuery.value.trace_id = 'trace-from-45-days-ago';
    await flushPromises();

    expect(wrapper.find('select').element.value).toBe('account_default');
    expect(getMock).toHaveBeenCalledTimes(3);
    expect(getMock.mock.calls.at(-1)[0]).toEqual(
      expect.objectContaining({ trace_id: 'trace-from-45-days-ago' })
    );
    expect(getMock.mock.calls.at(-1)[0]).not.toHaveProperty('since');
    expect(getMock.mock.calls.at(-1)[0]).not.toHaveProperty('until');
    expect(wrapper.findAll('table tbody tr')).toHaveLength(1);
  });

  it('filters by agent ID while retaining both supported feature families', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper
      .get('input[aria-label="CAPTAIN.OBSERVABILITY.FILTERS.ASSISTANT_ID"]')
      .setValue('42');
    await buttonByLabel(
      wrapper,
      'CAPTAIN.OBSERVABILITY.ACTIONS.APPLY_FILTERS'
    ).trigger('click');
    await flushPromises();

    expect(getMock).toHaveBeenLastCalledWith(
      expect.objectContaining({
        assistant_id: '42',
        features: ['assistant', 'captain_agent'],
        event_name: 'llm.chat.complete',
        page: 1,
      })
    );
  });

  it('filters a conversation and requests all of its events', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper
      .get(
        'input[aria-label="CAPTAIN.OBSERVABILITY.FILTERS.CONVERSATION_DISPLAY_ID"]'
      )
      .setValue('501');
    await buttonByLabel(
      wrapper,
      'CAPTAIN.OBSERVABILITY.ACTIONS.APPLY_FILTERS'
    ).trigger('click');
    await flushPromises();

    expect(getMock).toHaveBeenLastCalledWith(
      expect.objectContaining({
        conversation_display_id: '501',
        page: 1,
      })
    );
    const params = getMock.mock.calls.at(-1)[0];
    expect(params).not.toHaveProperty('features');
    expect(params).not.toHaveProperty('event_name');
  });

  it('keeps the active filter when moving to another page', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper
      .get('input[aria-label="CAPTAIN.OBSERVABILITY.FILTERS.ASSISTANT_ID"]')
      .setValue('42');
    await buttonByLabel(
      wrapper,
      'CAPTAIN.OBSERVABILITY.ACTIONS.APPLY_FILTERS'
    ).trigger('click');
    await flushPromises();

    await wrapper.get('[data-testid="next-page"]').trigger('click');
    await flushPromises();

    expect(getMock).toHaveBeenLastCalledWith(
      expect.objectContaining({
        assistant_id: '42',
        features: ['assistant', 'captain_agent'],
        event_name: 'llm.chat.complete',
        page: 2,
      })
    );
  });

  it('shows the empty state when there are no matching events', async () => {
    getMock.mockResolvedValue({
      data: {
        payload: [],
        time_series: { points: [], bucket: 'hour' },
        meta: { count: 0, current_page: 1, per_page: 25 },
      },
    });

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain('CAPTAIN.OBSERVABILITY.LOGS.EMPTY_TITLE');
  });

  it('shows a retryable error state after a failed request', async () => {
    getMock.mockRejectedValueOnce(new Error('network failure'));

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain('CAPTAIN.OBSERVABILITY.SIMPLE.LOAD_ERROR');
    expect(alertMock).toHaveBeenCalledWith(
      'CAPTAIN.OBSERVABILITY.SIMPLE.LOAD_ERROR'
    );

    getMock.mockResolvedValue(response);
    await buttonByLabel(
      wrapper,
      'CAPTAIN.OBSERVABILITY.SIMPLE.REFRESH'
    ).trigger('click');
    await flushPromises();

    expect(wrapper.findAll('table tbody tr')).toHaveLength(1);
  });

  it('reloads when the selected time range changes', async () => {
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

    const picker = wrapper.get('[data-calendar-only]');
    expect(picker.attributes('data-force-open')).toBe('false');
    expect(picker.attributes('data-hide-trigger')).toBe('false');
    const trigger = wrapper.get(
      '[data-test-id="custom-range-calendar-trigger"]'
    );
    expect(trigger.exists()).toBe(true);
    expect(
      wrapper.find('[data-test-id="custom-range-calendar"]').exists()
    ).toBe(false);

    await trigger.trigger('click');
    await wrapper.get('[data-test-id="select-custom-start"]').trigger('click');
    await wrapper.get('[data-test-id="select-custom-end"]').trigger('click');
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

    expect(
      wrapper.find('[data-test-id="custom-range-calendar"]').exists()
    ).toBe(false);
    await trigger.trigger('click');
    expect(
      wrapper.find('[data-test-id="custom-range-calendar"]').exists()
    ).toBe(true);
    await wrapper.get('[data-test-id="select-custom-start"]').trigger('click');
    await wrapper.get('[data-test-id="select-custom-end"]').trigger('click');
    await flushPromises();

    expect(getMock).toHaveBeenCalledTimes(3);
    expect(getMock).toHaveBeenLastCalledWith(
      expect.objectContaining({
        since: String(
          Math.floor(new Date('2026-09-01T00:00:00Z').getTime() / 1000)
        ),
        until: String(
          Math.floor(new Date('2026-09-10T23:59:59Z').getTime() / 1000)
        ),
      })
    );
  });
});
