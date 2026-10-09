# frozen_string_literal: true

class Api::V1::Accounts::ReportsController < Api::V1::Accounts::BaseController
  rescue_from ArgumentError, with: :render_unprocessable_entity
  before_action :authorize_report_access!, only: %i[calls leads]

  def calls
    report = ::Reports::CallsQuery.new(account: Current.account, params: report_params)
    render_payload(report.perform, meta: report.meta)
  end

  def leads
    report = ::Reports::LeadsQuery.new(account: Current.account, params: report_params)
    render_payload(report.perform, meta: report.meta)
  end

  private

  def authorize_report_access!
    return if performed?

    authorize :report, :view?
  rescue Pundit::NotAuthorizedError => error
    log_handled_error(error)
    render json: { error: 'You are not authorized to do this action' }, status: :forbidden
  end

  def report_params
    params.permit(:from_date, :to_date)
  end

  def render_payload(payload, status: :ok, meta: nil)
    body = { payload: payload }
    body[:meta] = meta if meta.present?
    render json: body, status: status
  end

  def render_unprocessable_entity(error)
    render json: { code: 'INVALID_REPORT_RANGE', error: error.message },
           status: :unprocessable_content
  end
end
