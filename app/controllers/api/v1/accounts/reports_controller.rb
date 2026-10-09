# frozen_string_literal: true

class Api::V1::Accounts::ReportsController < Api::V1::Accounts::BaseController
  rescue_from ArgumentError, with: :render_unprocessable_entity

  def calls
    authorize :report, :view?

    report = ::Reports::CallsQuery.new(account: Current.account, params: report_params)
    render_payload(report.perform, meta: report.meta)
  end

  def leads
    authorize :report, :view?

    report = ::Reports::LeadsQuery.new(account: Current.account, params: report_params)
    render_payload(report.perform, meta: report.meta)
  end

  private

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
