/* eslint-disable vue/one-component-per-file */
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const getMock = vi.fn();
const alertMock = vi.fn();

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) => `${key}${params.count ?? ''}`,
    locale: { value: 'en' },
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

describe('AI Agent logs', () => {
  beforeEach(() => {
    getMock.mockReset();
    getMock.mockResolvedValue(response);
    alertMock.mockReset();
  });

  it('requests completed AI Agent calls for the selected time range', async () => {
    mount(ObservabilityIndex);
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
