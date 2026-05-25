class Weixin::SyncChannelsJob < ApplicationJob
  queue_as :scheduled_jobs

  SYNCABLE_CONNECTION_STATES = %w[connecting connected failed rate_limited].freeze
  SKIPPED_LIFECYCLE_STATES = %w[pending_auth disconnected].freeze

  def perform
    syncable_channels.find_each do |channel|
      sync_channel(channel)
    end
  end

  private

  def syncable_channels
    Channel::Weixin
      .joins(:account)
      .includes(:inbox)
      .merge(Account.active)
      .where(connection_state: SYNCABLE_CONNECTION_STATES)
      .where.not(lifecycle_state: SKIPPED_LIFECYCLE_STATES)
      .order(:id)
  end

  def sync_channel(channel)
    return if channel.inbox.blank? || channel.inbox.deleting?
    return if channel.resolved_ilink_token.blank?

    Weixin::GatewayClient.new(channel: channel).sync_channel!
    channel.update!(last_synced_at: Time.current)
  rescue StandardError => e
    Rails.logger.warn("[WEIXIN] periodic sync failed for channel=#{channel.id}: #{e.class}: #{e.message}")
  end
end
