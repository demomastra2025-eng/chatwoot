# frozen_string_literal: true

class Crm::Contracts::RenewalSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(account_id = nil)
    account = account_id.present? ? Account.find_by(id: account_id) : nil
    return if account_id.present? && account.nil?

    Crm::Contracts::RenewalSweepService.new(account: account).perform
  end
end
