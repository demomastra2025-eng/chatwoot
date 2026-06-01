/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const getMock = vi.fn();
const releaseCheckMock = vi.fn();
const exportMock = vi.fn();
const updatePreferencesMock = vi.fn();
const routerReplaceMock = vi.fn();
const routerResolveMock = vi.fn();
const useAlertMock = vi.fn();
const writeTextMock = vi.fn();
let routeQuery = { tab: 'overview' };

const ButtonStub = defineComponent({
  name: 'NextButtonStub',
  props: {
    label: { type: String, default: '' },
    isLoading: { type: Boolean, default: false },
    disabled: { type: Boolean, default: false },
  },
  emits: ['click'],
  setup(props, { emit }) {
    return () =>
      h(
        'button',
        {
          disabled: props.isLoading || props.disabled,
          onClick: () => emit('click'),
        },
        props.label
      );
  },
});

const InputStub = defineComponent({
  name: 'InputStub',
  props: {
    modelValue: { type: [String, Number, Boolean, Array], default: '' },
    label: { type: String, default: '' },
    placeholder: { type: String, default: '' },
  },
  emits: ['update:modelValue'],
  setup(props, { emit }) {
    return () =>
      h('label', [
        props.label || props.placeholder,
        h('input', {
          value: props.modelValue,
          onInput: event => emit('update:modelValue', event.target.value),
        }),
      ]);
  },
});

const SelectStub = defineComponent({
  name: 'SelectStub',
  props: {
    modelValue: { type: [String, Number, Boolean, Array], default: '' },
    label: { type: String, default: '' },
    options: { type: Array, default: () => [] },
  },
  emits: ['update:modelValue'],
  setup(props, { emit }) {
    return () =>
      h('label', [
        props.label,
        h(
          'select',
          {
            value: props.modelValue,
            onChange: event => emit('update:modelValue', event.target.value),
          },
          props.options.map(option =>
            h(
              'option',
              { key: option.value, value: option.value },
              option.label
            )
          )
        ),
      ]);
  },
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values) => {
      if (!values) return key;
      return Object.entries(values).reduce(
        (message, [name, value]) => message.replace(`{${name}}`, String(value)),
        key
      );
    },
    locale: { value: 'en' },
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    name: 'captain_observability',
    params: { accountId: '6' },
    query: routeQuery,
  }),
  useRouter: () => ({ replace: routerReplaceMock, resolve: routerResolveMock }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/api/captain/observability', () => ({
  default: {
    get: getMock,
    releaseCheck: releaseCheckMock,
    export: exportMock,
  },
}));

vi.mock('dashboard/api/captain/preferences', () => ({
  default: {
    updatePreferences: updatePreferencesMock,
  },
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    setup(_props, { slots }) {
      return () =>
        h('main', [slots.subHeader?.(), slots.controls?.(), slots.body?.()]);
    },
  }),
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: ButtonStub,
}));

vi.mock('dashboard/components-next/input/Input.vue', () => ({
  default: InputStub,
}));

vi.mock('dashboard/components-next/select/Select.vue', () => ({
  default: SelectStub,
}));

vi.mock('dashboard/components-next/tabbar/TabBar.vue', () => ({
  default: defineComponent({
    name: 'TabBar',
    props: {
      tabs: { type: Array, default: () => [] },
    },
    setup(props) {
      return () =>
        h(
          'nav',
          props.tabs.map(tab => h('span', { key: tab.id }, tab.label))
        );
    },
  }),
}));

vi.mock('dashboard/components-next/table/BaseTable.vue', () => ({
  default: defineComponent({ name: 'BaseTable', template: '<div />' }),
}));

vi.mock('shared/components/charts/LineChart.vue', () => ({
  default: defineComponent({ name: 'LineChart', template: '<div />' }),
}));

vi.mock('./EventDetailsDialog.vue', () => ({
  default: defineComponent({
    name: 'EventDetailsDialog',
    setup(_props, { expose }) {
      expose({ open: vi.fn() });
      return () => h('div');
    },
  }),
}));

const { default: ObservabilityIndex } = await import('./Index.vue');

const overviewPayload = {
  data: {
    snapshot: {
      total_events: 3,
      request_count: 1,
      error_count: 1,
      blocked_count: 0,
      avg_duration_ms: 240,
      all_total_tokens: 1200,
      all_thinking_tokens: 120,
      total_estimated_cost: 0.0123,
      moderation_count: 0,
      zero_completion_recovered_count: 1,
      context_transform_applied_count: 2,
    },
    time_series: { bucket: 'hour', points: [] },
    release_gate: { status: 'pass', checks: [] },
    alerts: { status: 'ok', alerts: [] },
    runtime_health: {
      status: 'critical',
      evaluated_at: '2026-05-22T12:00:00Z',
      date_range: {
        started_at: '2026-05-22T11:00:00Z',
        ended_at: '2026-05-22T12:00:00Z',
      },
      checks: [
        {
          name: 'event_ingestion',
          status: 'pass',
          severity: 'info',
          actual: 3,
          message: 'LLM events are being persisted for this window.',
        },
        {
          name: 'provider_failures',
          status: 'fail',
          severity: 'critical',
          actual: 1,
          message: 'Provider failure events were recorded in this window.',
        },
        {
          name: 'payload_budget',
          status: 'warn',
          severity: 'warning',
          actual: 2,
          message: 'Some LLM event payload summaries were truncated.',
        },
        {
          name: 'otel_event_export',
          status: 'disabled',
          severity: 'info',
          actual: { status: 'disabled', sample_rate_valid: true },
          message: 'EventBus OTel export is disabled.',
        },
      ],
      top_providers: { openrouter: 2, openai: 1 },
      top_models: { 'openrouter/anthropic/claude-sonnet-4': 2 },
      recent_error_codes: { provider_unavailable: 1 },
    },
    performance_budget: {
      status: 'fail',
      total_project_cases: 2,
      uncovered_event_count: 1,
      cases: [
        {
          project_case_id: 'support_reply',
          event_count: 21,
          request_count: 20,
          status: 'pass',
          checks: [
            {
              name: 'p95_duration_ms',
              status: 'pass',
              value: 420,
              budget: 8000,
            },
          ],
        },
        {
          project_case_id: 'voice_inbound',
          event_count: 1,
          request_count: 1,
          status: 'fail',
          checks: [
            {
              name: 'request_error_rate',
              status: 'fail',
              value: 1,
              budget: 0.05,
            },
          ],
        },
      ],
    },
    alert_delivery_state: {},
    preferences: {},
    payload: [],
    meta: { count: 0, current_page: 1, per_page: 25 },
  },
};

describe('Captain observability page', () => {
  beforeEach(() => {
    getMock.mockReset();
    getMock.mockResolvedValue(overviewPayload);
    releaseCheckMock.mockReset();
    exportMock.mockReset();
    updatePreferencesMock.mockReset();
    routerReplaceMock.mockReset();
    routerResolveMock.mockReset();
    routerResolveMock.mockImplementation(({ query }) => ({
      href: `/app/accounts/6/captain/observability?${new URLSearchParams(
        query
      ).toString()}`,
    }));
    useAlertMock.mockReset();
    writeTextMock.mockReset();
    writeTextMock.mockResolvedValue();
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: writeTextMock },
      configurable: true,
    });
    routeQuery = { tab: 'overview' };
  });

  it('renders bounded runtime health without raw payload details', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CAPTAIN.OBSERVABILITY.RUNTIME_HEALTH.TITLE'
    );
    expect(wrapper.text()).toContain('CAPTAIN.OBSERVABILITY.STATUS.CRITICAL');
    expect(wrapper.text()).toContain('Provider Failures');
    expect(wrapper.text()).toContain('Payload Budget');
    expect(wrapper.text()).toContain('openrouter (2)');
    expect(wrapper.text()).toContain('provider_unavailable (1)');
    expect(wrapper.text()).not.toContain('prompt');
    expect(wrapper.text()).not.toContain('messages');
  });

  it('renders per-case performance budget gates from persisted project case metrics', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CAPTAIN.OBSERVABILITY.PERFORMANCE_BUDGET.TITLE'
    );
    expect(wrapper.text()).toContain('CAPTAIN.OBSERVABILITY.STATUS.FAIL');
    expect(wrapper.text()).toContain('Support Reply');
    expect(wrapper.text()).toContain('Voice Inbound');
    expect(wrapper.text()).toContain(
      'CAPTAIN.OBSERVABILITY.PERFORMANCE_BUDGET.CHECK_VALUE'
    );
  });

  it('renders a compact trace why-summary without exposing raw payload text', async () => {
    routeQuery = { tab: 'traces' };
    getMock.mockResolvedValue({
      data: {
        ...overviewPayload.data,
        payload: [
          {
            id: 1,
            created_at: '2026-05-22T11:00:00Z',
            event_name: 'llm.chat.complete',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'completed',
            provider: 'openrouter',
            model: 'anthropic/claude-sonnet-4',
            trace_id: 'trace-why-1',
            total_tokens: 120,
            estimated_cost: 0.0031,
            details: { prompt: 'sensitive prompt', messages: ['raw message'] },
          },
          {
            id: 2,
            created_at: '2026-05-22T11:00:01Z',
            event_name: 'llm.tool.complete',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'completed',
            provider: 'openrouter',
            model: 'anthropic/claude-sonnet-4',
            trace_id: 'trace-why-1',
            tool_name: 'search_documentation',
            duration_ms: 250,
          },
          {
            id: 3,
            created_at: '2026-05-22T11:00:02Z',
            event_name: 'llm.schema.invalid',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'error',
            reason: 'schema_invalid',
            provider: 'openrouter',
            model: 'anthropic/claude-sonnet-4',
            trace_id: 'trace-why-1',
            schema_invalid: true,
            tool_failure: true,
            error: true,
          },
        ],
      },
    });

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain('CAPTAIN.OBSERVABILITY.TRACES.WHY_TITLE');
    expect(wrapper.text()).toContain('search_documentation');
    expect(wrapper.text()).toContain('Schema Invalid');
    expect(wrapper.text()).toContain(
      'CAPTAIN.OBSERVABILITY.FLAGS.TOOL_FAILURE'
    );
    expect(wrapper.text()).toContain('120');
    expect(wrapper.text()).not.toContain('sensitive prompt');
    expect(wrapper.text()).not.toContain('raw message');
  });

  it('groups trace reasons with counts in the focused why-summary and trace card', async () => {
    routeQuery = { tab: 'traces' };
    getMock.mockResolvedValue({
      data: {
        ...overviewPayload.data,
        payload: [
          {
            id: 11,
            created_at: '2026-05-22T11:00:00Z',
            event_name: 'llm.chat.failed',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'error',
            reason: 'provider_timeout',
            error: true,
            trace_id: 'trace-reasons-1',
          },
          {
            id: 12,
            created_at: '2026-05-22T11:00:01Z',
            event_name: 'llm.retry.failed',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'error',
            reason: 'provider_timeout',
            error: true,
            trace_id: 'trace-reasons-1',
          },
          {
            id: 13,
            created_at: '2026-05-22T11:00:02Z',
            event_name: 'llm.schema.invalid',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'error',
            reason: 'schema_invalid',
            error: true,
            trace_id: 'trace-reasons-1',
          },
        ],
      },
    });

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CAPTAIN.OBSERVABILITY.TRACES.WHY_REASONS'
    );
    expect(wrapper.text()).toContain('Provider Timeout (2)');
    expect(wrapper.text()).toContain('Schema Invalid (1)');
  });

  it('copies trace context with a deep link and grouped reasons', async () => {
    routeQuery = { tab: 'traces' };
    getMock.mockResolvedValue({
      data: {
        ...overviewPayload.data,
        payload: [
          {
            id: 21,
            created_at: '2026-05-22T11:00:00Z',
            event_name: 'llm.chat.failed',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'error',
            reason: 'provider_timeout',
            error: true,
            trace_id: 'trace-copy-1',
            session_id: 'session-copy-1',
            conversation_display_id: 42,
            copilot_thread_id: 'thread-copy-1',
            assistant_id: 7,
          },
          {
            id: 22,
            created_at: '2026-05-22T11:00:01Z',
            event_name: 'llm.retry.failed',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'error',
            reason: 'provider_timeout',
            error: true,
            trace_id: 'trace-copy-1',
            session_id: 'session-copy-1',
            conversation_display_id: 42,
            copilot_thread_id: 'thread-copy-1',
            assistant_id: 7,
          },
        ],
      },
    });

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    const copyContextButton = wrapper
      .findAll('button')
      .find(
        button =>
          button.text() === 'CAPTAIN.OBSERVABILITY.ACTIONS.COPY_TRACE_CONTEXT'
      );
    expect(copyContextButton).toBeTruthy();

    await copyContextButton.trigger('click');
    await flushPromises();

    expect(writeTextMock).toHaveBeenCalledTimes(1);
    const copiedContext = writeTextMock.mock.calls[0][0];
    expect(copiedContext).toContain('trace-copy-1');
    expect(copiedContext).toContain('session-copy-1');
    expect(copiedContext).toContain('42');
    expect(copiedContext).toContain('Provider Timeout (2)');
    expect(copiedContext).toContain('trace_id=trace-copy-1');
    expect(copiedContext).toContain('session_id=session-copy-1');
    expect(copiedContext).toContain('conversation_display_id=42');
    expect(useAlertMock).toHaveBeenCalledWith(
      'CAPTAIN.OBSERVABILITY.ACTIONS.TRACE_CONTEXT_COPIED'
    );
  });

  it('alerts when trace context copy fails', async () => {
    routeQuery = { tab: 'traces' };
    writeTextMock.mockRejectedValueOnce(new Error('clipboard blocked'));
    getMock.mockResolvedValue({
      data: {
        ...overviewPayload.data,
        payload: [
          {
            id: 31,
            created_at: '2026-05-22T11:00:00Z',
            event_name: 'llm.chat.failed',
            feature: 'assistant',
            runtime_mode: 'captain_runtime',
            status: 'error',
            reason: 'provider_timeout',
            error: true,
            trace_id: 'trace-copy-fail-1',
          },
        ],
      },
    });

    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    const copyContextButton = wrapper
      .findAll('button')
      .find(
        button =>
          button.text() === 'CAPTAIN.OBSERVABILITY.ACTIONS.COPY_TRACE_CONTEXT'
      );
    expect(copyContextButton).toBeTruthy();

    await copyContextButton.trigger('click');
    await flushPromises();

    expect(useAlertMock).toHaveBeenCalledWith(
      'CAPTAIN.OBSERVABILITY.ACTIONS.TRACE_CONTEXT_COPY_ERROR'
    );
  });
});
