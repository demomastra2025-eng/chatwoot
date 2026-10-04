# frozen_string_literal: true

class Accounts::StorageThresholdAlertJob < ApplicationJob
  queue_as :housekeeping

  # Without an id: the periodic check of every account that has a storage quota.
  # With an id: a single account, enqueued when an upload was just rejected for lack of space.
  def perform(account_id = nil)
    return AccountLimits::StorageAlertService.check_all_accounts! if account_id.blank?

    account = Account.find_by(id: account_id)
    AccountLimits::StorageAlertService.new(account: account).perform if account
  end
end
