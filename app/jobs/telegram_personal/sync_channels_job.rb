class TelegramPersonal::SyncChannelsJob < ApplicationJob
  queue_as :scheduled_jobs

  SKIPPED_CONNECTION_STATES = %w[auth_required].freeze
  SKIPPED_LIFECYCLE_STATES = %w[pending_auth code_sent qr_ready qr_expired password_required disconnected].freeze

  def perform
    syncable_channels.find_each do |channel|
      sync_channel(channel)
    end
  end

  private

  def syncable_channels
    Channel::TelegramPersonal
      .joins(:account)
      .includes(:inbox)
      .merge(Account.active)
      .where.not(string_session: nil)
      .where.not(connection_state: SKIPPED_CONNECTION_STATES)
      .where.not(lifecycle_state: SKIPPED_LIFECYCLE_STATES)
      .order(:id)
  end

  def sync_channel(channel)
    return if channel.inbox.blank? || channel.inbox.deleting?
    return if channel.string_session.blank?

    result = TelegramPersonal::GatewayClient.new(channel: channel).sync_channel!
    persist_sync_result(channel, result)
  rescue StandardError => e
    Rails.logger.warn("[TELEGRAM PERSONAL] periodic sync failed for channel=#{channel.id}: #{e.class}: #{e.message}")
  end

  def persist_sync_result(channel, result)
    now = Time.current
    channel_attrs = result.is_a?(Hash) ? result.with_indifferent_access[:channel] : nil
    return touch_last_synced_at(channel, now) if channel_attrs.blank?

    next_attrs = resolved_channel_attrs(channel, channel_attrs)
    if state_changed?(channel, next_attrs)
      channel.apply_runtime_update!(next_attrs.merge(last_synced_at: now))
    else
      touch_last_synced_at(channel, now)
    end
  end

  def touch_last_synced_at(channel, timestamp)
    channel.update_column(:last_synced_at, timestamp) # rubocop:disable Rails/SkipsModelValidations
  end

  def resolved_channel_attrs(channel, channel_attrs)
    next_connection = channel_attrs[:connection_state].presence || channel.connection_state
    next_lifecycle = channel_attrs[:lifecycle_state].presence || channel.lifecycle_state

    {
      connection_state: next_connection,
      lifecycle_state: next_lifecycle,
      last_error: resolved_last_error(channel, channel_attrs, next_connection, next_lifecycle),
      runtime_state: resolved_runtime_state(channel, channel_attrs),
      string_session: channel_attrs[:string_session].presence || channel.string_session
    }
  end

  def resolved_last_error(channel, channel_attrs, next_connection, next_lifecycle)
    return nil if channel.clear_last_error?(channel_attrs, { connection_state: next_connection, lifecycle_state: next_lifecycle })
    return channel_attrs[:last_error] if channel_attrs.key?(:last_error)

    channel.last_error
  end

  def resolved_runtime_state(channel, channel_attrs)
    return channel.runtime_state_payload unless channel_attrs.key?(:runtime_state)

    channel.normalize_runtime_state_payload(channel_attrs[:runtime_state])
  end

  def state_changed?(channel, next_attrs)
    channel.connection_state != next_attrs[:connection_state] ||
      channel.lifecycle_state != next_attrs[:lifecycle_state] ||
      channel.last_error != next_attrs[:last_error] ||
      channel.string_session != next_attrs[:string_session] ||
      channel.runtime_state_payload != next_attrs[:runtime_state]
  end
end
