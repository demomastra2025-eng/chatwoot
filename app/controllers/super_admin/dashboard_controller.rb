# frozen_string_literal: true

class SuperAdmin::DashboardController < SuperAdmin::ApplicationController
  def index
    force_refresh = params[:refresh].present? || params[:force_refresh].present?
    # The figures of the tiles and the checks of «Нужно проверить» are kept for a short while, so the page does not run them on every visit
    @summary = SuperAdmin::DashboardSummary.build(force_refresh: force_refresh)
    @health_accounts, @health_summary = SuperAdmin::HealthMatrixService.build(force_refresh: force_refresh)
    @alerts = SuperAdmin::DashboardAlerts.build(force_refresh: force_refresh)
    @checklist = SuperAdmin::DashboardChecklist.build(alerts: @alerts, health_accounts: @health_accounts, health_summary: @health_summary)
  end
end
