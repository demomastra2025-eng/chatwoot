class Crm::Appointments::EvaluateDealJob < ApplicationJob
  queue_as :low

  def perform(account_id, deal_id)
    deal = Crm::Deal.find_by(account_id: account_id, id: deal_id)
    Crm::Appointments::AutomationService.new(deal: deal).perform if deal
  end
end
