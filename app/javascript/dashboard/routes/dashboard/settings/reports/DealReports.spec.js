import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import CrmReportsAPI from 'dashboard/api/crm/reports';
import DealReports from './DealReports.vue';
import CRMActivityReports from './components/CRMActivityReports.vue';

vi.mock('dashboard/api/crm/reports', () => ({
  default: {
    deals: vi.fn(),
    dealsWithoutNextAction: vi.fn(),
    funnels: vi.fn(),
    managerEffectiveness: vi.fn(),
    stageDurations: vi.fn(),
    taskResults: vi.fn(),
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'en' },
    t: key => key,
  }),
}));

const response = rows => ({ data: { meta: {}, payload: { rows } } });

describe('DealReports', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    CrmReportsAPI.deals.mockRejectedValue(
      new Error('Deals report unavailable')
    );
    CrmReportsAPI.managerEffectiveness.mockResolvedValue(response([]));
    CrmReportsAPI.stageDurations.mockResolvedValue(response([]));
    CrmReportsAPI.taskResults.mockResolvedValue(response([]));
    CrmReportsAPI.dealsWithoutNextAction.mockResolvedValue(
      response([{ no_action_count: 1 }])
    );
  });

  it('keeps the activity section available after the existing deal report fails', async () => {
    const from = Math.floor(new Date(2026, 9, 1, 0, 0, 0).getTime() / 1000);
    const to = Math.floor(new Date(2026, 9, 4, 23, 59, 59).getTime() / 1000);
    const reportFiltersStub = {
      emits: ['filterChange'],
      mounted() {
        this.$emit('filterChange', { from, to, groupBy: { period: 'day' } });
      },
      template: '<div />',
    };

    const wrapper = mount(DealReports, {
      global: {
        mocks: { $t: key => key },
        stubs: {
          BarChart: true,
          DoughnutChart: true,
          LineChart: true,
          ReportFilters: reportFiltersStub,
          ReportHeader: true,
        },
      },
    });
    await flushPromises();

    const activityButton = wrapper
      .findAll('button')
      .find(button =>
        button.text().includes('CRM_DEAL_REPORTS.SECTIONS.ACTIVITY.TITLE')
      );
    expect(activityButton).toBeDefined();

    await activityButton.trigger('click');
    await flushPromises();

    expect(wrapper.findComponent(CRMActivityReports).exists()).toBe(true);
    expect(CrmReportsAPI.stageDurations).toHaveBeenCalledWith({
      as_of_date: '2026-10-04',
      from_date: '2026-10-01',
      to_date: '2026-10-04',
    });
    expect(CrmReportsAPI.dealsWithoutNextAction).toHaveBeenCalledWith();
  });
});
