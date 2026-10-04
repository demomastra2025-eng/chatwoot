import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';

import CrmReportsAPI from 'dashboard/api/crm/reports';
import enReport from 'dashboard/i18n/locale/en/report.json';
import ruReport from 'dashboard/i18n/locale/ru/report.json';
import CrmActivityReports from '../CRMActivityReports.vue';

vi.mock('dashboard/api/crm/reports', () => ({
  default: {
    dealsWithoutNextAction: vi.fn(),
    stageDurations: vi.fn(),
    taskResults: vi.fn(),
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'en' },
    t: (key, params = {}) => [key, ...Object.values(params)].join(' '),
  }),
}));

const response = rows => ({ data: { meta: {}, payload: { rows } } });

const mountReports = () => {
  const from = Math.floor(new Date(2026, 9, 1, 0, 0, 0).getTime() / 1000);
  const to = Math.floor(new Date(2026, 9, 4, 23, 59, 59).getTime() / 1000);

  return mount(CrmActivityReports, {
    props: { from, to },
    global: {
      mocks: {
        $t: (key, params = {}) => [key, ...Object.values(params)].join(' '),
      },
    },
  });
};

describe('CRMActivityReports', () => {
  it('defines localized task count labels with a count placeholder', () => {
    const countKeys = [
      'COUNT_EXACT',
      'COUNT_ESTIMATED',
      'COUNT_UNKNOWN',
      'STAGE_ROW_PASSES',
      'STAGE_EXACT_COUNT',
      'STAGE_ESTIMATED_COUNT',
    ];
    const dashboardKeys = [
      'KPI_GROUP_ARIA',
      'KPI_PERIOD_HINT',
      'KPI_STAGE_PASSES',
      'KPI_STAGE_NOTE',
      'KPI_EVENT_HINT',
      'KPI_COMPLETED_EVENTS',
      'KPI_CANCELLED_EVENTS',
      'KPI_EVENT_NOTE',
      'KPI_NO_ACTION',
      'KPI_CURRENT_NOTE',
      'CURRENT_BADGE',
      'STAGE_PLOT_TITLE',
      'MEDIAN_SHORT',
      'P75_SHORT',
      'STAGE_AXIS_ARIA',
      'STAGE_SERIES_ARIA',
      'STAGE_DEFINITION_LABEL',
      'COVERAGE_DETAILS',
      'TASK_DISTRIBUTION_TITLE',
      'TASK_DISTRIBUTION_SUBTITLE',
      'TASK_DISTRIBUTION_EMPTY',
      'TASK_DISTRIBUTION_ARIA',
      'TASK_RESULTS_SUBTITLE',
      'TASK_DEFINITION_LABEL',
      'LIFECYCLE_EVENTS',
      'OTHER_LIFECYCLE',
      'NO_ACTION_SUBTITLE',
      'NO_ACTION_DEFINITION_LABEL',
    ];

    [enReport, ruReport].forEach(report => {
      const activityLabels = report.CRM_DEAL_REPORTS.ACTIVITY;

      countKeys.forEach(key => {
        const label = activityLabels[key];

        expect(label).toEqual(expect.any(String));
        expect(label).toContain('{count}');
        expect(label).not.toContain('CRM_DEAL_REPORTS.ACTIVITY');
      });

      dashboardKeys.forEach(key => {
        expect(activityLabels[key]).toEqual(expect.any(String));
        expect(activityLabels[key]).not.toContain('CRM_DEAL_REPORTS.ACTIVITY');
      });
      expect(activityLabels.STAGE_AXIS_ARIA).toContain('{unit}');
      expect(activityLabels.TASK_DISTRIBUTION_ARIA).toContain('{total}');
      expect(activityLabels.TASK_DISTRIBUTION_ARIA).toContain('{completed}');
      expect(activityLabels.TASK_DISTRIBUTION_ARIA).toContain('{cancelled}');
      expect(activityLabels.TASK_DISTRIBUTION_ARIA).toContain('{other}');
    });
  });

  beforeEach(() => {
    vi.resetAllMocks();
    CrmReportsAPI.stageDurations.mockResolvedValue(response([]));
    CrmReportsAPI.taskResults.mockResolvedValue(response([]));
    CrmReportsAPI.dealsWithoutNextAction.mockResolvedValue(
      response([{ no_action_count: 0 }])
    );
  });

  it('shares the selected calendar range with historical reports only', async () => {
    const wrapper = mountReports();
    await flushPromises();

    expect(CrmReportsAPI.stageDurations).toHaveBeenCalledWith({
      as_of_date: '2026-10-04',
      from_date: '2026-10-01',
      to_date: '2026-10-04',
    });
    expect(CrmReportsAPI.taskResults).toHaveBeenCalledWith({
      as_of_date: '2026-10-04',
      from_date: '2026-10-01',
      to_date: '2026-10-04',
    });
    expect(CrmReportsAPI.dealsWithoutNextAction).toHaveBeenCalledWith();
    expect(
      wrapper
        .find('[data-testid="kpi-stage-passes"] .activity-kpi-value')
        .text()
    ).toBe('0');
    expect(
      wrapper
        .find('[data-testid="kpi-completed-events"] .activity-kpi-value')
        .text()
    ).toBe('0');
    expect(
      wrapper
        .find('[data-testid="kpi-cancelled-events"] .activity-kpi-value')
        .text()
    ).toBe('0');
    expect(
      wrapper.find('[data-testid="kpi-no-action"] .activity-kpi-value').text()
    ).toBe('0');
  });

  it('shows an unavailable state without presenting a fallback zero', async () => {
    CrmReportsAPI.dealsWithoutNextAction.mockRejectedValueOnce({
      response: { status: 404 },
    });

    const wrapper = mountReports();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.ERRORS.UNAVAILABLE'
    );
    expect(wrapper.text()).not.toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.NO_ACTION_EMPTY'
    );
    expect(
      wrapper.find('[data-testid="kpi-no-action"] .activity-kpi-value').text()
    ).toBe('—');
  });

  it('sums stage passages and task event occurrences while keeping median and p75 on one scale', async () => {
    CrmReportsAPI.stageDurations.mockResolvedValueOnce(
      response([
        {
          pipeline_id: 4,
          pipeline_name: 'Sales',
          stage_id: 22,
          stage_name: 'Long stage',
          stage_outcome: 'open',
          total_count: 4,
          median_duration_seconds: 0,
          p75_duration_seconds: 432000,
          exact_count: 4,
          estimated_count: 0,
          unknown_count: 0,
          coverage: 'exact',
        },
        {
          pipeline_id: 4,
          pipeline_name: 'Sales',
          stage_id: 23,
          stage_name: 'Short stage',
          stage_outcome: 'open',
          total_count: 5,
          median_duration_seconds: 3600,
          p75_duration_seconds: 7200,
          exact_count: 0,
          estimated_count: 5,
          unknown_count: 0,
          coverage: 'estimated',
        },
      ])
    );
    CrmReportsAPI.taskResults.mockResolvedValueOnce(
      response([
        {
          task_type: { id: 3, name: 'Call' },
          task_outcome: { id: 8, name: 'Reached' },
          lifecycle_type: 'completed',
          occurrence_count: 2,
          exact_count: 2,
          estimated_count: 0,
          unknown_count: 0,
        },
        {
          task_type: { id: 3, name: 'Call' },
          task_outcome: { id: 8, name: 'Reached' },
          lifecycle_type: 'completed',
          occurrence_count: 3,
          exact_count: 3,
          estimated_count: 0,
          unknown_count: 0,
          assignee: { id: 14, name: 'Hidden group' },
        },
        {
          task_type: { id: 4, name: 'Meeting' },
          task_outcome: { id: 9, name: 'Rescheduled' },
          lifecycle_type: 'cancelled',
          occurrence_count: 4,
          exact_count: 4,
          estimated_count: 0,
          unknown_count: 0,
        },
      ])
    );

    const wrapper = mountReports();
    await flushPromises();

    expect(
      wrapper
        .find('[data-testid="kpi-stage-passes"] .activity-kpi-value')
        .text()
    ).toBe('9');
    expect(
      wrapper
        .find('[data-testid="kpi-completed-events"] .activity-kpi-value')
        .text()
    ).toBe('5');
    expect(
      wrapper
        .find('[data-testid="kpi-cancelled-events"] .activity-kpi-value')
        .text()
    ).toBe('4');
    expect(
      wrapper
        .find('[data-testid="stage-comparison-chart"]')
        .attributes('data-unit')
    ).toContain('UNITS.DAYS');

    const bars = wrapper.findAll('[data-testid="stage-comparison-bar"]');
    expect(bars.map(bar => bar.attributes('data-series'))).toEqual([
      'median',
      'p75',
      'median',
      'p75',
    ]);
    expect(bars.map(bar => bar.attributes('data-unit'))).toEqual([
      'CRM_DEAL_REPORTS.ACTIVITY.UNITS.DAYS',
      'CRM_DEAL_REPORTS.ACTIVITY.UNITS.DAYS',
      'CRM_DEAL_REPORTS.ACTIVITY.UNITS.DAYS',
      'CRM_DEAL_REPORTS.ACTIVITY.UNITS.DAYS',
    ]);
    const stageRows = wrapper.findAll('[data-testid="stage-duration-row"]');
    expect(
      stageRows[0].findAll('.activity-stage-measure > strong')[0].text()
    ).toContain('0 ');
    expect(
      stageRows[1].findAll('.activity-stage-measure > strong')[0].text()
    ).toContain('<0.1');
  });

  it('combines task result groups that differ only by hidden attribution', async () => {
    CrmReportsAPI.taskResults.mockResolvedValueOnce(
      response([
        {
          task_type: { id: 3, name: 'Follow up' },
          task_outcome: { id: 8, name: 'Contacted' },
          lifecycle_type: 'completed',
          occurrence_count: 2,
          exact_count: 1,
          estimated_count: 1,
          unknown_count: 0,
          coverage: 'estimated',
          assignee: { id: 12, name: 'A' },
        },
        {
          task_type: { id: 3, name: 'Follow up' },
          task_outcome: { id: 8, name: 'Contacted' },
          lifecycle_type: 'completed',
          occurrence_count: 3,
          exact_count: 2,
          estimated_count: 0,
          unknown_count: 1,
          coverage: 'unknown',
          assignee: { id: 19, name: 'B' },
        },
        {
          task_type: { id: 4, name: 'Follow up' },
          task_outcome: { id: 9, name: 'Contacted' },
          lifecycle_type: 'completed',
          occurrence_count: 7,
          exact_count: 7,
          estimated_count: 0,
          unknown_count: 0,
          coverage: 'exact',
          assignee: { id: 19, name: 'B' },
        },
      ])
    );

    const wrapper = mountReports();
    await flushPromises();

    const rows = wrapper.findAll('[data-testid="task-result-row"]');
    expect(rows).toHaveLength(2);
    expect(rows[0].text()).toContain('Follow up');
    expect(rows[0].text()).toContain('Contacted');
    expect(
      rows.map(row => row.find('[data-testid="task-result-count"]').text())
    ).toEqual(['5', '7']);
    expect(rows[0].text()).toContain('CRM_DEAL_REPORTS.ACTIVITY.COUNT_EXACT 3');
    expect(rows[0].text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.COUNT_ESTIMATED 1'
    );
    expect(rows[0].text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.COUNT_UNKNOWN 1'
    );
    expect(rows[0].text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.COVERAGE.UNKNOWN'
    );
  });

  it('keeps renamed historical stage groups separate when names or outcome change', async () => {
    CrmReportsAPI.stageDurations.mockResolvedValueOnce(
      response([
        {
          pipeline_id: 4,
          pipeline_name: 'Old pipeline name',
          stage_id: 22,
          stage_name: 'Old stage name',
          stage_outcome: 'open',
          total_count: 2,
          median_duration_seconds: 3600,
          p75_duration_seconds: 7200,
          exact_count: 2,
          estimated_count: 0,
          coverage: 'exact',
        },
        {
          pipeline_id: 4,
          pipeline_name: 'Current pipeline name',
          stage_id: 22,
          stage_name: 'Current stage name',
          stage_outcome: 'won',
          total_count: 4,
          median_duration_seconds: 10800,
          p75_duration_seconds: 14400,
          exact_count: 4,
          estimated_count: 0,
          coverage: 'exact',
        },
      ])
    );

    const wrapper = mountReports();
    await flushPromises();

    const rows = wrapper.findAll('[data-testid="stage-duration-row"]');
    expect(rows).toHaveLength(2);
    expect(rows[0].text()).toContain('Old pipeline name');
    expect(rows[0].text()).toContain('Old stage name');
    expect(rows[0].text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.STAGE_OUTCOMES.OPEN'
    );
    expect(rows[1].text()).toContain('Current pipeline name');
    expect(rows[1].text()).toContain('Current stage name');
    expect(rows[1].text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.STAGE_OUTCOMES.WON'
    );
  });

  it('shows unknown-before stage coverage without inventing an unknown passage count', async () => {
    CrmReportsAPI.stageDurations.mockResolvedValueOnce(
      response([
        {
          pipeline_id: 4,
          pipeline_name: 'Sales',
          stage_id: 22,
          stage_name: 'History boundary',
          stage_outcome: 'open',
          total_count: 3,
          median_duration_seconds: 3600,
          p75_duration_seconds: 7200,
          exact_count: 1,
          estimated_count: 2,
          coverage: 'unknown_before',
          reliable_since: '2026-01-01',
        },
      ])
    );

    const wrapper = mountReports();
    await flushPromises();

    const row = wrapper.find('[data-testid="stage-duration-row"]');
    expect(row.text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.COVERAGE.UNKNOWN_BEFORE'
    );
    expect(row.text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.STAGE_EXACT_COUNT 1'
    );
    expect(row.text()).toContain(
      'CRM_DEAL_REPORTS.ACTIVITY.STAGE_ESTIMATED_COUNT 2'
    );
    expect(row.text()).not.toContain('STAGE_UNKNOWN_COUNT');
  });
});
