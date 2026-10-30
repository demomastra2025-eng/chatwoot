# frozen_string_literal: true

class OwnerFinance::SyncState < ApplicationRecord
  validates :sync_key, presence: true, uniqueness: true
  validates :sync_status, presence: true

  def self.record!(key, status:, summary: {})
    rec = find_or_initialize_by(sync_key: key)
    rec.update!(
      sync_status: status,
      last_synced_at: Time.current,
      summary: summary
    )
    rec
  end
end
