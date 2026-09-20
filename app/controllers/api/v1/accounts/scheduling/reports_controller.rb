class Api::V1::Accounts::Scheduling::ReportsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :authorize_appointment_reports!

  def meetings_by_specialist
    query = meetings_by_specialist_query
    render_payload({ rows: query.aggregate_rows }, meta: query.meta)
  end

  def meetings_by_specialist_details
    query = meetings_by_specialist_query
    render_payload({ rows: query.drill_down_rows }, meta: query.pagination_meta)
  end

  private

  def authorize_appointment_reports!
    authorize Scheduling::Appointment, :view_reports?
  end

  def meetings_by_specialist_query
    Scheduling::Reports::MeetingsBySpecialistQuery.new(
      account: Current.account,
      appointments_scope: report_appointments_scope,
      params: report_params
    )
  end

  def report_appointments_scope
    Scheduling::AppointmentPolicy::Scope.intersection(
      pundit_user,
      Current.account.scheduling_appointments,
      capabilities: %w[view view_reports]
    )
  end

  def report_params
    params.permit(:from_local, :to_local, :resource_id, :team_id, :service_id, :status, :as_of, :page, :per_page)
  end
end
