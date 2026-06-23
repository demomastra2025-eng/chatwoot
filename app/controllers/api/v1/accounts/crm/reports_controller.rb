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

  alias funnels deals

  private

  def deal_report_params
    params.permit(:since, :until, :group_by, :currency, :pipeline_id)
  end
end
