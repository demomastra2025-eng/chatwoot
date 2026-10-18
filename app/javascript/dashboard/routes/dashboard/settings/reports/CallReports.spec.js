import { reactive } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import ReportsAPI from 'dashboard/api/standaloneReports';
import CallReports from './CallReports.vue';

vi.mock('./components/ReportHeader.vue', () => ({
  default: { template: '<header />' },
}));

const route = reactive({ params: { accountId: '43' } });
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => route,
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'ru' },
    te: key => key.startsWith('REPORTS.CALLS.STATUSES.'),
    t: (key, params = {}) => [key, ...Object.values(params)].join(' '),
  }),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));
vi.mock('dashboard/api/standaloneReports', () => ({
  default: { getCalls: vi.fn() },
}));

const sampleResponse = () => ({
  data: {
    payload: {
      summary: {
        logical_call_count: 10,
        answered_count: 8,
        unanswered_count: 2,
        inbound_count: 7,
        outbound_count: 3,
        answer_rate_percent: 80.0,
        average_answered_duration_seconds: 95,
      },
      daily_breakdown: [
        {
          date: '2026-10-18',
          logical_call_count: 10,
          answered_count: 8,
          unanswered_count: 2,
        },
      ],
      rows: [
        {
          id: 101,
          direction: 'inbound',
          status: 'completed',
          started_at: '2026-10-18T09:15:00Z',
          answered_at: '2026-10-18T09:15:05Z',
          duration_seconds: 95,
          provider: 'sipuni',
          inbox_name: 'Клиника Алматы',
          contact_id: 55,
          contact_name: 'Алия Серикова',
          conversation_id: 777,
          from_number: '+77015554433',
          to_number: '+77270001122',
        },
        {
          id: 102,
          direction: 'inbound',
          status: 'completed',
          started_at: '2026-10-18T10:00:00Z',
          answered_at: null,
          duration_seconds: null,
          provider: 'binotel',
          inbox_name: 'Клиника Алматы',
          contact_id: null,
          contact_name: null,
          conversation_id: null,
          from_number: '+77029998877',
          to_number: '+77270001122',
        },
      ],
      coverage: {
        complete: true,
        sampled_calls: 10,
        limit: 50000,
      },
    },
    meta: {
      from_date: '2026-10-12',
      to_date: '2026-10-18',
      timezone: 'Asia/Almaty',
      max_range_days: 90,
    },
  },
});

const mountReport = () =>
  mount(CallReports, {
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
        BarChart: {
          name: 'BarChart',
          props: ['collection'],
          template: '<div />',
        },
        RouterLink: {
          props: ['to'],
          template: '<a :href="to"><slot /></a>',
        },
        Button: true,
        Spinner: true,
      },
    },
  });

describe('CallReports', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    route.params.accountId = '43';
    ReportsAPI.getCalls.mockResolvedValue(sampleResponse());
  });

  it('renders KPI metrics with answer rate, daily chart, contact details, and maps unanswered completed calls to no_answer', async () => {
    const wrapper = mountReport();
    await flushPromises();

    expect(wrapper.text()).toContain('REPORTS.CALLS.ANSWERED_CALLS:8 (80%)');
    expect(wrapper.text()).toContain('Алия Серикова');
    expect(wrapper.text()).toContain('+77015554433');
    expect(wrapper.text()).toContain('#777');
    expect(wrapper.text()).toContain('Sipuni');
    expect(wrapper.text()).toContain('Binotel');
    expect(wrapper.text()).toContain('REPORTS.CALLS.STATUSES.completed');
    expect(wrapper.text()).toContain('REPORTS.CALLS.STATUSES.no_answer');

    const chart = wrapper.findComponent({ name: 'BarChart' });
    expect(chart.exists()).toBe(true);
    expect(chart.props('collection').datasets[0].data).toEqual([8]);
    expect(chart.props('collection').datasets[1].data).toEqual([2]);

    wrapper.unmount();
  });
});
