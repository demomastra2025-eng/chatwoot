class Channels::WhatsappWeb::ReconcileHistoryJob < MutexApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100
  CURSOR_KEY = 'WHATSAPP_WEB_HISTORY_RECONCILE_CURSOR'.freeze
  LOCK_KEY = 'WHATSAPP_WEB_HISTORY_RECONCILE_MUTEX'.freeze

  retry_on LockAcquisitionError, wait: 30.seconds, attempts: 3

  def perform
    with_lock(LOCK_KEY, 1.minute) do
      cursor = ::Redis::Alfred.get(CURSOR_KEY).to_i
      channels = syncable_channels.where('channel_whatsapp_web.id > ?', cursor).limit(BATCH_SIZE).to_a
      channels.each { |channel| reconcile(channel) }
      next_cursor = channels.size == BATCH_SIZE ? channels.last.id : 0
      ::Redis::Alfred.setex(CURSOR_KEY, next_cursor.to_s, 30.days)
    end
  end

  private

  def syncable_channels
    Channel::WhatsappWeb.joins(:account, :inbox).includes(:inbox)
                        .merge(Account.active)
                        .where(connection_state: 'open', lifecycle_state: 'connected', inboxes: { deleting_at: nil })
                        .order(:id)
  end

  def reconcile(channel)
    return if channel.provider_history_synced_at.blank?
    return if channel.full_history_baseline_current? || channel.history_sync_request_pending?
    return if ::Redis::LockManager.new.locked?(format(::Redis::Alfred::WHATSAPP_WEB_HISTORY_SYNC_MUTEX, channel_id: channel.id))

    channel.request_history_sync!('full', expected_provider_history_synced_at: channel.provider_history_synced_at)
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP WEB] History reconciliation failed for channel=#{channel.id}: #{e.class}")
  end
end
