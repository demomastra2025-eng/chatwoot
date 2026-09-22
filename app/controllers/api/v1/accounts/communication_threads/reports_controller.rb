class Api::V1::Accounts::CommunicationThreads::ReportsController < Api::V1::Accounts::BaseController
  before_action :ensure_communication_threads_feature_enabled!

  rescue_from CommunicationThreads::WorkloadQuery::InvalidQuery, with: :render_invalid_query

  def workload = render_workload

  def workload_details = render_workload(details: true)

  private

  def render_workload(details: false)
    authorize CommunicationThread, :view_reports?
    query = CommunicationThreads::WorkloadQuery.new(
      account: Current.account,
      threads_scope: report_threads_scope,
      params: workload_params
    )
    rows = details ? query.drill_down_rows : query.aggregate_rows
    meta = details ? query.pagination_meta : query.meta

    render json: { payload: { rows: rows }, meta: meta }
  end

  def report_threads_scope
    CommunicationThreadPolicy::Scope.intersection(
      pundit_user,
      CommunicationThread.where(account_id: Current.account.id),
      capabilities: %w[view view_reports]
    )
  end

  def workload_params
    params.permit(
      :dimension, :assignee_id, :team_id, :status, :priority, :unread, :page, :per_page,
      :from, :to, :as_of, :from_date, :to_date, :as_of_date, :since, :until, :start_at, :end_at
    )
  end

  def ensure_communication_threads_feature_enabled!
    return if Current.account&.feature_enabled?('communication_threads')

    render json: { error: 'Communication threads are not enabled for this account', code: 'FEATURE_DISABLED' }, status: :forbidden
  end

  def render_invalid_query(error)
    render json: { error: error.message, code: 'INVALID_REPORT_QUERY' }, status: :unprocessable_content
  end
end
