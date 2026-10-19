# frozen_string_literal: true

class Accounts::StorageBreakdownRefreshJob < ApplicationJob
  queue_as :housekeeping

  SWEEP_BATCH_SIZE = 200

  def perform(account_id = nil)
    if account_id.present?
      account = Account.find_by(id: account_id)
      refresh(account) if account
    else
      sweep_stale_accounts
    end
  end

  private

  def sweep_stale_accounts
    Account.select(:id).find_in_batches(batch_size: SWEEP_BATCH_SIZE) do |batch|
      snapshots = Accounts::StorageOverviewService.snapshots_for(batch)
      batch.each do |account|
        service = Accounts::StorageOverviewService.new(account: account)
        next unless service.stale?(snapshots[account.id])

        service.schedule_refresh
      end
    end
  end

  def refresh(account)
    service = Accounts::StorageOverviewService.new(account: account)
    return unless service.claim_refresh(job_id)

    claimed = true
    result = service.refresh!(job_id: job_id)
    superseded = result.nil? || service.stale?(result)
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("[StorageBreakdownRefreshJob] Query failed for account #{account.id}: #{e.class.name}")
  rescue StandardError => e
    Rails.logger.warn("[StorageBreakdownRefreshJob] Failed for account #{account.id}: #{e.class.name}")
  ensure
    if claimed
      Accounts::StorageOverviewService.release_refresh(account.id, job_id)
      service.schedule_refresh(force: true) if superseded
    end
  end
end
