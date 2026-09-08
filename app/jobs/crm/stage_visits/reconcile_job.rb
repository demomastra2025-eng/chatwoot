class Crm::StageVisits::ReconcileJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(account_id: nil)
    account = Account.find(account_id) if account_id.present?
    report = Crm::StageVisits::ReconciliationService.new(account: account, auto_fix: false).perform
    Rails.logger.info("CRM StageVisit reconciliation: #{report.to_json}")
    report
  end
end
