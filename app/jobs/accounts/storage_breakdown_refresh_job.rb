# frozen_string_literal: true

class Accounts::StorageBreakdownRefreshJob < ApplicationJob
  queue_as :low

  def perform(account_id = nil)
    if account_id.present?
      account = Account.find_by(id: account_id)
      refresh(account) if account
    else
      Account.find_each do |account|
        refresh(account)
      end
    end
  end

  private

  def refresh(account)
    Accounts::StorageOverviewService.new(account: account).refresh!
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("[StorageBreakdownRefreshJob] Query failed for account #{account.id}: #{e.class.name}")
  rescue StandardError => e
    Rails.logger.warn("[StorageBreakdownRefreshJob] Failed for account #{account.id}: #{e.class.name}")
  end
end
