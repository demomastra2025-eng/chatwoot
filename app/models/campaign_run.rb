# == Schema Information
#
# Table name: campaign_runs
#
#  id               :bigint           not null, primary key
#  completed_at     :datetime
#  error_message    :text
#  failed_count     :integer          default(0), not null
#  metadata         :jsonb            not null
#  processed_count  :integer          default(0), not null
#  skipped_count    :integer          default(0), not null
#  started_at       :datetime
#  status           :integer          default("queued"), not null
#  successful_count :integer          default(0), not null
#  total_count      :integer          default(0), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  campaign_id      :bigint           not null
#  inbox_id         :bigint           not null
#
# Indexes
#
#  index_campaign_runs_on_account_id                  (account_id)
#  index_campaign_runs_on_account_id_and_created_at   (account_id,created_at)
#  index_campaign_runs_on_campaign_id                 (campaign_id)
#  index_campaign_runs_on_campaign_id_and_created_at  (campaign_id,created_at)
#  index_campaign_runs_on_inbox_id                    (inbox_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (campaign_id => campaigns.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#
class CampaignRun < ApplicationRecord
  SUCCESSFUL_DELIVERY_STATUSES = %w[pending submitted sent delivered read].freeze

  belongs_to :account
  belongs_to :campaign
  belongs_to :inbox

  has_many :campaign_deliveries, dependent: :nullify

  enum status: {
    queued: 0,
    running: 1,
    completed: 2,
    failed: 3,
    cancelled: 4
  }

  validates :total_count, :processed_count, :successful_count, :failed_count, :skipped_count,
            numericality: { greater_than_or_equal_to: 0 }

  def start!(total_count:, metadata: {})
    update!(
      status: :running,
      total_count: total_count,
      started_at: Time.current,
      completed_at: nil,
      error_message: nil,
      processed_count: 0,
      successful_count: 0,
      failed_count: 0,
      skipped_count: 0,
      metadata: (self.metadata || {}).merge(metadata.compact)
    )
  end

  def complete_from_deliveries!(audience_size:)
    snapshot = delivery_snapshot_attributes(audience_size)

    update!(
      status: snapshot[:successful_count].positive? ? :completed : :failed,
      completed_at: Time.current,
      error_message: snapshot[:successful_count].positive? ? nil : (error_message.presence || 'No deliveries succeeded'),
      **snapshot
    )
  end

  def fail!(message, audience_size: total_count)
    update!(
      status: :failed,
      completed_at: Time.current,
      error_message: message,
      **delivery_snapshot_attributes(audience_size)
    )
  end

  def cancel!(message = 'Cancelled by user', audience_size: total_count)
    update!(
      status: :cancelled,
      completed_at: Time.current,
      error_message: message,
      **delivery_snapshot_attributes(audience_size)
    )
  end

  def progress_percentage
    return 0 if total_count.to_i <= 0

    ((processed_count.to_f / total_count) * 100).round
  end

  def refresh_delivery_snapshot!
    snapshot = delivery_snapshot_attributes(total_count)
    update_attributes = snapshot

    if completed? || failed?
      next_status = terminal_status_for_snapshot(snapshot)
      update_attributes = update_attributes.merge(
        status: next_status,
        error_message: next_status == :failed ? (error_message.presence || 'No deliveries succeeded') : nil
      )
    end

    update!(**update_attributes)
    campaign.sync_status_from_run!(reload)
  end

  private

  def delivery_snapshot_attributes(audience_size)
    grouped_statuses = campaign_deliveries.reorder(nil).group(:status).count.transform_keys do |key|
      CampaignDelivery.statuses.key(key) || key.to_s
    end

    successful_count = SUCCESSFUL_DELIVERY_STATUSES.sum { |status| grouped_statuses[status] || 0 }
    failed_count = grouped_statuses['failed'] || 0
    skipped_count = grouped_statuses['skipped'] || 0

    {
      total_count: audience_size,
      processed_count: successful_count + failed_count + skipped_count,
      successful_count: successful_count,
      failed_count: failed_count,
      skipped_count: skipped_count
    }
  end

  def terminal_status_for_snapshot(snapshot)
    snapshot[:successful_count].positive? ? :completed : :failed
  end
end
