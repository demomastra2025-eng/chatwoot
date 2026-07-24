class WhatsappWeb::LifecycleLock
  LOCK_TTL = 5.minutes.to_i

  class LockAcquisitionError < StandardError; end

  def initialize(channel_id:)
    @lock_key = format(Redis::Alfred::WHATSAPP_WEB_LIFECYCLE_MUTEX, channel_id: channel_id)
  end

  def with_lock
    token = SecureRandom.uuid
    lock_acquired = Redis::Alfred.set(@lock_key, token, nx: true, ex: LOCK_TTL)
    raise LockAcquisitionError, 'Another WhatsApp Web operation is already in progress' unless lock_acquired

    yield
  ensure
    Redis::Alfred.delete_if_value(@lock_key, token) if lock_acquired
  end
end
