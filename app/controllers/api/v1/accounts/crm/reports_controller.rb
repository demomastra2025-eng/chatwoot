class Api::V1::Accounts::Crm::ReportsController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!, except: %i[task_results task_result_details]
  before_action :ensure_crm_tasks_enabled!, only: %i[task_results task_result_details deals_without_next_action deals_without_next_action_details]

  def deals
    authorize :report, :view?

    report = ::Crm::Reports::FunnelsService.new(
      account: Current.account,
      params: deal_report_params
    )

    render_payload(report.perform, meta: report.meta)
  end

  def manager_effectiveness
    authorize :report, :view?

    report = ::Crm::Reports::ManagerEffectivenessService.new(
      account: Current.account,
      params: manager_effectiveness_report_params
    )

    render_payload(report.perform, meta: report.meta)
  end

  def stage_durations
    authorize :report, :view?

    report = ::Crm::Reports::StageDurationsQuery.new(
      account: Current.account,
      deals_scope: policy_scope(::Crm::Deal).where(account_id: Current.account.id),
      params: stage_duration_report_params
    )

    render_payload({ rows: report.aggregate_rows }, meta: report.meta)
  end

  def stage_duration_details
    authorize :report, :view?

    report = ::Crm::Reports::StageDurationsQuery.new(
      account: Current.account,
      deals_scope: policy_scope(::Crm::Deal).where(account_id: Current.account.id),
      params: stage_duration_details_params
    )

    render_payload({ rows: report.drill_down_rows }, meta: report.pagination_meta)
  end

  def task_results
    authorize :report, :view?

    report = ::Crm::Reports::TaskResultsQuery.new(
      account: Current.account,
      tasks_scope: policy_scope(::Crm::Task).where(account_id: Current.account.id),
      params: task_results_report_params
    )

    render_payload({ rows: report.aggregate_rows }, meta: report.meta)
  end

  def task_result_details
    authorize :report, :view?

    report = ::Crm::Reports::TaskResultsQuery.new(
      account: Current.account,
      tasks_scope: policy_scope(::Crm::Task).where(account_id: Current.account.id),
      params: task_result_details_params
    )

    render_payload({ rows: report.drill_down_rows }, meta: report.pagination_meta)
  end

  def deals_without_next_action
    authorize :report, :view?

    report = ::Crm::Reports::DealsWithoutNextActionQuery.new(
      account: Current.account,
      deals_scope: policy_scope(::Crm::Deal).where(account_id: Current.account.id),
      tasks_scope: policy_scope(::Crm::Task).where(account_id: Current.account.id),
      params: deals_without_next_action_report_params
    )

    render_payload({ rows: report.aggregate_rows }, meta: report.meta)
  end

  def deals_without_next_action_details
    authorize :report, :view?

    report = ::Crm::Reports::DealsWithoutNextActionQuery.new(
      account: Current.account,
      deals_scope: policy_scope(::Crm::Deal).where(account_id: Current.account.id),
      tasks_scope: policy_scope(::Crm::Task).where(account_id: Current.account.id),
      params: deals_without_next_action_details_params
    )

    render_payload({ rows: report.drill_down_rows }, meta: report.pagination_meta)
  end

  alias funnels deals

  private

  def stage_duration_report_params
    params.permit(:from_date, :to_date, :pipeline_id, :stage_id)
  end

  def stage_duration_details_params
    params.permit(:from_date, :to_date, :pipeline_id, :stage_id, :page, :per_page)
  end

  def task_results_report_params
    params.permit(:from_date, :to_date, :as_of_date, :task_type_id, :task_outcome_id, :lifecycle_type, :reliability)
  end

  def task_result_details_params
    params.permit(:from_date, :to_date, :as_of_date, :task_type_id, :task_outcome_id, :lifecycle_type, :reliability, :page, :per_page)
  end

  def deals_without_next_action_report_params
    params.permit(:pipeline_id, :stage_id, :owner_id, :team_id, :page, :per_page)
  end

  def deals_without_next_action_details_params
    params.permit(:pipeline_id, :stage_id, :owner_id, :team_id, :page, :per_page)
  end

  def deal_report_params
    params.permit(:since, :until, :group_by, :currency, :pipeline_id)
  end

  def manager_effectiveness_report_params
    params.permit(:since, :until, :currency, :pipeline_id, :call_duration_threshold_seconds)
  end
end
