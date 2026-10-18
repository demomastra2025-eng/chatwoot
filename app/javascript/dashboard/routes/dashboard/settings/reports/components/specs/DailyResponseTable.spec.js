import { flushPromises, mount } from '@vue/test-utils';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import DailyResponseTable from '../DailyResponseTable.vue';
import standaloneReportsAPI from 'dashboard/api/standaloneReports';
import * as downloadHelper from 'dashboard/helper/downloadHelper';

vi.mock('dashboard/api/standaloneReports', () => ({
  default: {
    getDailyResponse: vi.fn(),
  },
}));

vi.mock('dashboard/helper/downloadHelper', () => ({
  downloadCsvFile: vi.fn(),
  downloadExcelFile: vi.fn(),
  generateFileName: vi.fn(({ type, extension = 'csv' }) => `${type}.${extension}`),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    params: { accountId: '64' },
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStoreGetters: () => ({
    getCurrentAccountId: { value: 64 },
    'accounts/getAccount': {
      value: () => ({ settings: { timezone: 'Asia/Almaty' } }),
    },
  }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
    locale: { value: 'ru' },
  }),
}));

const sampleReport = {
  period: {
    from: '2026-04-01',
    to: '2026-04-02',
    timezone: 'Asia/Almaty',
  },
  summary: {
    total: 10,
    answered: 8,
    unanswered: 2,
    answered_share_percent: 80.0,
  },
  rows: [
    {
      date: '2026-04-01',
      iso_weekday: 3,
      total: 6,
      answered: 5,
      unanswered: 1,
      answered_share_percent: 83.3,
      avg_first_response_seconds: 180,
      avg_reply_wait_seconds: 420,
    },
    {
      date: '2026-04-02',
      iso_weekday: 4,
      total: 4,
      answered: 3,
      unanswered: 1,
      answered_share_percent: 75.0,
      avg_first_response_seconds: 3900,
      avg_reply_wait_seconds: 45,
    },
  ],
};

describe('DailyResponseTable', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    standaloneReportsAPI.getDailyResponse.mockResolvedValue({
      data: { payload: sampleReport },
    });
  });

  it('fetches and renders daily response summary and rows', async () => {
    const wrapper = mount(DailyResponseTable, {
      props: {
        from: 1775001600,
        to: 1775088000,
      },
      global: {
        stubs: {
          ReportMetricCard: {
            props: ['label', 'value'],
            template: '<div class="metric-stub">{{ label }}: {{ value }}</div>',
          },
          Spinner: true,
        },
      },
    });

    await flushPromises();

    expect(standaloneReportsAPI.getDailyResponse).toHaveBeenCalledWith({
      fromDate: '2026-04-01',
      toDate: '2026-04-02',
    });
    expect(wrapper.text()).toContain('01.04.2026');
    expect(wrapper.text()).toContain('02.04.2026');
    expect(wrapper.text()).toContain('83.3%');
    expect(wrapper.text()).toContain('80%');
  });

  it('exports CSV and Excel files when export buttons are clicked', async () => {
    const wrapper = mount(DailyResponseTable, {
      props: {
        from: 1775001600,
        to: 1775088000,
      },
      global: {
        stubs: {
          ReportMetricCard: true,
          Spinner: true,
        },
      },
    });

    await flushPromises();

    const buttons = wrapper.findAll('button');
    await buttons[0].trigger('click');
    await buttons[1].trigger('click');

    expect(downloadHelper.downloadExcelFile).toHaveBeenCalledTimes(1);
    expect(downloadHelper.downloadCsvFile).toHaveBeenCalledTimes(1);
  });
});
