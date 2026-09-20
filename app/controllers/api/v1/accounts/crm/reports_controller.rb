class Api::V1::Accounts::Crm::ReportsController < Api::V1::Accounts::Crm::BaseController
  TASK_REPORT_ACTIONS = %i[task_lifecycle task_lifecycle_details task_results task_result_details].freeze

  before_action :ensure_crm_deals_enabled!, except: TASK_REPORT_ACTIONS
  before_action :ensure_crm_tasks_enabled!, only: TASK_REPORT_ACTIONS

  def deals
    authorize ::Crm::Deal, :view_reports?

    report = ::Crm::Reports::FunnelsService.new(
      account: Current.account,
      deals_scope: report_deals_scope,
      params: deal_report_params
    )

    render_payload(report.perform, meta: report.meta)
  end

  def manager_effectiveness
    authorize ::Crm::Deal, :view_reports?

    report = ::Crm::Reports::ManagerEffectivenessService.new(
      account: Current.account,
      deals_scope: report_deals_scope,
      tasks_scope: report_tasks_scope,
      visible_owner_ids: report_owner_ids,
      params: manager_effectiveness_report_params
    )

    render_payload(report.perform, meta: report.meta)
  end

  def stage_transitions
    authorize ::Crm::Deal, :view_reports?

    query = stage_transitions_query
    render_payload({ rows: query.aggregate_rows }, meta: query.meta)
  end

  def stage_transition_details
    authorize ::Crm::Deal, :view_reports?

    query = stage_transitions_query
    render_payload({ rows: query.drill_down_rows }, meta: query.pagination_meta)
  end

  def stage_durations
    authorize ::Crm::Deal, :view_reports?

    query = stage_durations_query
    render_payload({ rows: query.aggregate_rows }, meta: query.meta)
  end

  def stage_duration_details
    authorize ::Crm::Deal, :view_reports?

    query = stage_durations_query
    render_payload({ rows: query.drill_down_rows }, meta: query.pagination_meta)
  end

  def conversions
    authorize ::Crm::Deal, :view_reports?

    query = conversions_query
    render_payload({ rows: query.aggregate_rows }, meta: query.meta)
  end

  def conversion_details
    authorize ::Crm::Deal, :view_reports?

    query = conversions_query
    render_payload({ rows: query.drill_down_rows }, meta: query.pagination_meta)
  end

  def task_lifecycle
    authorize ::Crm::Task, :view_reports?

    query = task_lifecycle_query
    render_payload({ rows: query.aggregate_rows }, meta: query.meta)
  end

  def task_lifecycle_details
    authorize ::Crm::Task, :view_reports?

    query = task_lifecycle_query
    render_payload({ rows: query.drill_down_rows }, meta: query.pagination_meta)
  end

  def task_results
    authorize ::Crm::Task, :view_reports?

    query = task_results_query
    render_payload({ rows: query.aggregate_rows }, meta: query.meta)
  end

  def task_result_details
    authorize ::Crm::Task, :view_reports?

    query = task_results_query
    render_payload({ rows: query.drill_down_rows }, meta: query.pagination_meta)
  end

  alias funnels deals

  private

  def report_deals_scope
    ::Crm::DealPolicy::Scope.intersection(
      pundit_user,
      Current.account.crm_deals,
      capabilities: %w[view view_reports]
    )
  end

  def report_owner_ids
    access_scope = ::Crm::DealPolicy::Scope.intersection_access_scope(
      pundit_user,
      capabilities: %w[view view_reports]
    )
    ::Crm::DealPolicy::Scope.owner_ids(pundit_user, access_scope: access_scope)
  end

  def report_tasks_scope
    ::Crm::TaskPolicy::Scope.intersection(
      pundit_user,
      Current.account.crm_tasks,
      capabilities: %w[view view_reports]
    )
  end

  def deal_report_params
    params.permit(:since, :until, :group_by, :currency, :pipeline_id)
  end

  def manager_effectiveness_report_params
    params.permit(:since, :until, :currency, :pipeline_id, :call_duration_threshold_seconds)
  end

  def stage_transitions_query
    ::Crm::Reports::StageTransitionsQuery.new(
      account: Current.account,
      deals_scope: report_deals_scope,
      params: stage_transition_report_params
    )
  end

  def stage_transition_report_params
    params.permit(
      :from_date,
      :to_date,
      :from_pipeline_id,
      :from_stage_id,
      :pipeline_id,
      :stage_id,
      :page,
      :per_page
    )
  end

  def stage_durations_query
    ::Crm::Reports::StageDurationsQuery.new(
      account: Current.account,
      deals_scope: report_deals_scope,
      params: stage_duration_report_params
    )
  end

  def stage_duration_report_params
    params.permit(:from_date, :to_date, :pipeline_id, :stage_id, :page, :per_page)
  end

  def conversions_query
    ::Crm::Reports::ConversionsQuery.new(
      account: Current.account,
      deals_scope: report_deals_scope,
      params: conversion_report_params
    )
  end

  def conversion_report_params
    params.permit(:from_date, :to_date, :as_of_date, :pipeline_id, :outcome, :closing_reason, :page, :per_page)
  end

  def task_lifecycle_query
    ::Crm::Reports::TaskLifecycleQuery.new(
      account: Current.account,
      tasks_scope: report_tasks_scope,
      params: task_lifecycle_report_params
    )
  end

  def task_lifecycle_report_params
    params.permit(:from_date, :to_date, :as_of_date, :lifecycle_type, :deadline_state, :page, :per_page)
  end

  def task_results_query
    ::Crm::Reports::TaskResultsQuery.new(
      account: Current.account,
      tasks_scope: report_tasks_scope,
      params: task_results_report_params
    )
  end

  def task_results_report_params
    params.permit(
      :from_date, :to_date, :as_of_date, :task_type_id, :task_outcome_id, :lifecycle_type, :reliability, :page, :per_page
    )
  end
end
