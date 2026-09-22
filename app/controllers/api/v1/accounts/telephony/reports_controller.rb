class Api::V1::Accounts::Telephony::ReportsController < Api::V1::Accounts::Telephony::BaseController
  before_action :authorize_logical_call_reports!

  def logical_calls
    query = logical_calls_query
    render_payload({ rows: query.aggregate_rows }, meta: query.meta)
  end

  def logical_call_details
    query = logical_calls_query
    render_payload({ rows: query.drill_down_rows }, meta: query.pagination_meta)
  end

  private

  def authorize_logical_call_reports!
    return if policy(Telephony::LogicalCallOccurrence).view_reports?

    render_report_not_authorized
  end

  def logical_calls_query
    Telephony::Reports::LogicalCallsQuery.new(
      account: Current.account,
      occurrences_scope: report_occurrences_scope,
      params: report_params
    )
  end

  def report_occurrences_scope
    Telephony::LogicalCallOccurrencePolicy::Scope.intersection(
      pundit_user,
      Current.account.telephony_logical_call_occurrences,
      capabilities: %w[view view_reports]
    )
  end

  def report_params
    params.permit(
      :from_local, :to_local, :as_of, :metric, :dimension, :direction, :provider, :inbox_id,
      :actor_kind, :actor_id, :actor_team_id, :assistant_id, :terminal_status, :reliability,
      :long_threshold_seconds, :page, :per_page
    )
  end

  def render_report_not_authorized
    render json: {
      code: 'NOT_AUTHORIZED',
      error: 'You are not authorized to view telephony reports',
      state: 'not_authorized'
    }, status: :forbidden
  end
end
