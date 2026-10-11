import { reactive } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import ReportsAPI from 'dashboard/api/standaloneReports';
import BotReports from './BotReports.vue';

vi.mock('./components/ReportHeader.vue', () => ({
  default: { template: '<header />' },
}));

const route = reactive({ params: { accountId: '74' } });
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => route,
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'ru' },
    t: (key, params = {}) => [key, ...Object.values(params)].join(' '),
  }),
}));
vi.mock('dashboard/api/standaloneReports', () => ({
  default: { getAiAgents: vi.fn() },
}));

const response = (messageCount = 12) => ({
  data: {
    payload: {
      totals: {
        message_count: messageCount,
        conversation_count: 4,
        completion_count: 2,
        handoff_count: 1,
        outcome_count: 3,
        classification_counts: { completed: 1, failed: 1, unclassified: 1 },
      },
      series: [
        {
          date: '2026-10-10',
          message_count: messageCount,
          completion_count: 2,
          handoff_count: 1,
        },
      ],
      agents: [{ id: 8, name: 'Consultant', active: true }],
      agent_breakdown: [
        {
          assistant_id: 8,
          name: 'Consultant',
          message_count: messageCount,
          conversation_count: 4,
          completion_count: 2,
          handoff_count: 1,
        },
      ],
      reasons: [
        {
          assistant_id: 8,
          type: 'handoff',
          reason_id: 'faq_no_answer',
          label: 'Нет ответа в FAQ',
          count: 1,
        },
      ],
    },
    meta: {
      from_date: '2026-10-01',
      to_date: '2026-10-10',
      timezone: 'Asia/Almaty',
      max_range_days: 90,
    },
  },
});
const mountReport = () =>
  mount(BotReports, {
    global: {
      stubs: {
        ReportHeader: true,
        ReportDateRange: {
          name: 'ReportDateRange',
          props: ['fromDate', 'toDate', 'timezone'],
          emits: ['apply'],
          template: '<div />',
        },
        ReportMetricCard: {
          props: ['label', 'value'],
          template: '<div>{{ label }}:{{ value }}</div>',
        },
        SelectMenu: {
          name: 'SelectMenu',
          props: ['modelValue', 'options', 'label'],
          emits: ['update:modelValue'],
          template: '<div>{{ label }}</div>',
        },
        BarChart: {
          name: 'BarChart',
          props: ['collection'],
          template: '<div />',
        },
        Button: true,
        Spinner: true,
      },
    },
  });

describe('AI agent report', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    route.params.accountId = '74';
    ReportsAPI.getAiAgents.mockResolvedValue(response());
  });

  it('shows actual counts, classifier failures and historical unclassified events separately', async () => {
    const wrapper = mountReport();
    await flushPromises();
    expect(wrapper.get('[data-testid="ai-report-totals"]').text()).toContain(
      'AI_REPORTS.MESSAGES:12'
    );
    expect(
      wrapper.get('[data-testid="classification-failed"]').text()
    ).toContain('1');
    expect(
      wrapper.get('[data-testid="classification-unclassified"]').text()
    ).toContain('1');
    expect(wrapper.text()).toContain('Нет ответа в FAQ');
    expect(wrapper.text()).toContain('AI_REPORTS.COUNTING_NOTE');
    expect(wrapper.text()).not.toContain('RESOLUTION_RATE');
    expect(
      wrapper.findComponent({ name: 'BarChart' }).props('collection')
        .datasets[0].data
    ).toEqual([12]);
    wrapper.unmount();
  });

  it('applies the selected period and agent to the same account-scoped request', async () => {
    const wrapper = mountReport();
    await flushPromises();
    expect(wrapper.findComponent({ name: 'SelectMenu' }).text()).toBe(
      'AI_REPORTS.ALL_AGENTS'
    );
    wrapper
      .findComponent({ name: 'SelectMenu' })
      .vm.$emit('update:modelValue', '8');
    await flushPromises();
    expect(ReportsAPI.getAiAgents).toHaveBeenLastCalledWith({
      fromDate: '2026-10-01',
      toDate: '2026-10-10',
      assistantId: '8',
    });
    expect(wrapper.findComponent({ name: 'SelectMenu' }).text()).toBe(
      'Consultant'
    );
    wrapper
      .findComponent({ name: 'ReportDateRange' })
      .vm.$emit('apply', { fromDate: '2026-09-01', toDate: '2026-09-10' });
    await flushPromises();
    expect(ReportsAPI.getAiAgents).toHaveBeenLastCalledWith({
      fromDate: '2026-09-01',
      toDate: '2026-09-10',
      assistantId: '8',
    });
    wrapper.unmount();
  });

  it('does not display failed requests as a successful report with zero activity', async () => {
    ReportsAPI.getAiAgents.mockRejectedValue(new Error('unavailable'));
    const wrapper = mountReport();
    await flushPromises();
    expect(wrapper.get('[role="alert"]').text()).toContain('AI_REPORTS.ERROR');
    expect(wrapper.find('[data-testid="ai-report-totals"]').exists()).toBe(
      false
    );
    wrapper.unmount();
  });

  it('discards a late response from another workspace', async () => {
    let finishOld;
    ReportsAPI.getAiAgents.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          finishOld = resolve;
        })
    );
    const wrapper = mountReport();
    route.params.accountId = '530';
    await flushPromises();
    finishOld(response(999));
    await flushPromises();
    expect(wrapper.get('[data-testid="ai-report-totals"]').text()).toContain(
      'AI_REPORTS.MESSAGES:12'
    );
    expect(wrapper.text()).not.toContain('999');
    wrapper.unmount();
  });
});
