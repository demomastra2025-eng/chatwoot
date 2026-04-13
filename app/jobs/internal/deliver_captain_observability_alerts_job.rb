# frozen_string_literal: true

class Internal::DeliverCaptainObservabilityAlertsJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Account.find_in_batches(batch_size: 100) do |accounts|
      accounts.each do |account|
        Llm::Monitoring::AlertNotifier.new(account: account).call
      end
    end
  end
end
