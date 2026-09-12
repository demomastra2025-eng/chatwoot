class Api::V1::Accounts::Crm::ReportsController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!

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
      visible_owner_ids: report_owner_ids,
      params: manager_effectiveness_report_params
    )

    render_payload(report.perform, meta: report.meta)
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

  def deal_report_params
    params.permit(:since, :until, :group_by, :currency, :pipeline_id)
  end

  def manager_effectiveness_report_params
    params.permit(:since, :until, :currency, :pipeline_id, :call_duration_threshold_seconds)
  end
end
