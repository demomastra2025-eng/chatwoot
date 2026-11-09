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
      changed_ids = accounts_with_recent_storage_changes(batch.map(&:id), snapshots)
      batch.each do |account|
        snapshot = snapshots[account.id]
        service = Accounts::StorageOverviewService.new(account: account)
        next unless service.stale?(snapshot)
        next unless storage_refresh_needed?(account.id, snapshot, service, changed_ids)

        service.schedule_refresh
      end
    end
  end

  def storage_refresh_needed?(account_id, snapshot, service, changed_ids)
    return true if snapshot && snapshot[:generation].to_i != service.send(:generation)

    changed_ids.include?(account_id)
  end

  def accounts_with_recent_storage_changes(account_ids, snapshots)
    return Set.new if account_ids.empty?

    cutoff = 25.hours.ago
    changed = Set.new
    changed.merge(Attachment.where(account_id: account_ids).where('updated_at >= ?', cutoff).distinct.pluck(:account_id))
    if defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?
      changed.merge(
        Telephony::CallSession.where(account_id: account_ids)
                              .where.not(recording_ref: [nil, ''])
                              .where('updated_at >= ?', cutoff)
                              .distinct
                              .pluck(:account_id)
      )
    end
    if defined?(Captain::Document) && Captain::Document.table_exists?
      changed.merge(Captain::Document.where(account_id: account_ids).where('updated_at >= ?', cutoff).distinct.pluck(:account_id))
    end
    # Also include accounts that have stored files/recordings but no initial snapshot yet
    missing_ids = account_ids.select { |id| snapshots[id].nil? } - changed.to_a
    if missing_ids.any?
      changed.merge(Attachment.where(account_id: missing_ids).distinct.pluck(:account_id))
      if defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?
        changed.merge(
          Telephony::CallSession.where(account_id: missing_ids).where.not(recording_ref: [nil, '']).distinct.pluck(:account_id)
        )
      end
    end
    changed
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
