# frozen_string_literal: true

class Accounts::StorageBreakdownRefreshJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(account_id = nil)
    if account_id.present?
      account = Account.find_by(id: account_id)
      account&.storage_breakdown(force_refresh: true)
    else
      Account.find_each do |account|
        account.storage_breakdown(force_refresh: true)
      rescue StandardError => e
        Rails.logger.warn("[StorageBreakdownRefreshJob] Failed for account #{account.id}: #{e.message}")
      end
    end
  end
end
