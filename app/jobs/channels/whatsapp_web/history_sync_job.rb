class Channels::WhatsappWeb::HistorySyncJob < MutexApplicationJob
  queue_as :whatsappweb_history
  LOCK_TIMEOUT = 30.minutes

  retry_on LockAcquisitionError, wait: 10.seconds, attempts: 60

  def perform(channel_id, mode = 'incremental', sync_context = {})
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank?
    return if stale_sync_request?(channel, sync_context)

    with_lock(lock_key(channel_id), LOCK_TIMEOUT) do
      channel = Channel::WhatsappWeb.find_by(id: channel_id)
      return if channel.blank?
      return if stale_sync_request?(channel, sync_context)

      WhatsappWeb::HistorySyncService.new(channel: channel, mode: mode, sync_context: sync_context).perform
    end
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP WEB] History sync failed for channel #{channel_id}: #{e.message}")
    raise
  end

  private

  def stale_sync_request?(channel, sync_context)
    context = sync_context.to_h.with_indifferent_access
    return false if context.blank?

    requested_at = parse_time(context[:requested_at])
    if requested_at.present? &&
       channel.history_sync_requested_at.present? &&
       channel.history_sync_requested_at > requested_at + 1.second
      Rails.logger.info("[WHATSAPP WEB] Skipping stale history sync request for channel #{channel.id}")
      return true
    end

    expected_provider_history_synced_at = parse_time(context[:expected_provider_history_synced_at])

    if channel.history_sync_request_fulfilled?(
      requested_at: requested_at,
      expected_provider_history_synced_at: expected_provider_history_synced_at
    )
      Rails.logger.info("[WHATSAPP WEB] Skipping already-fulfilled history sync request for channel #{channel.id}")
      return true
    end

    if expected_provider_history_synced_at.present? &&
       channel.provider_history_synced_at.present? &&
       channel.provider_history_synced_at > expected_provider_history_synced_at + 1.second
      Rails.logger.info("[WHATSAPP WEB] Skipping outdated provider snapshot sync for channel #{channel.id}")
      return true
    end

    false
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def lock_key(channel_id)
    format(::Redis::Alfred::WHATSAPP_WEB_HISTORY_SYNC_MUTEX, channel_id: channel_id)
  end
end
