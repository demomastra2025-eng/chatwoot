class Api::V1::Accounts::Crm::ReportsController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!

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

  alias funnels deals

  private

  def deal_report_params
    params.permit(:since, :until, :group_by, :currency, :pipeline_id)
  end

  def manager_effectiveness_report_params
    params.permit(:since, :until, :currency, :pipeline_id, :call_duration_threshold_seconds)
  end
end
