# frozen_string_literal: true

class Accounts::StorageThresholdAlertJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    AccountLimits::StorageAlertService.check_all_accounts!
  end
end
