class WhatsappWeb::PendingMessageStatusCache
  DEFAULT_TTL = 15.minutes.to_i

  pattr_initialize [:inbox_id!, :source_id!, { ttl: DEFAULT_TTL }]

  def write(status)
    return if status.blank?

    Redis::Alfred.set(redis_key, status.to_s, ex: ttl)
  end

  def consume
    status = peek
    Redis::Alfred.delete(redis_key) if status.present?
    status
  end

  def peek
    Redis::Alfred.get(redis_key)
  end

  private

  def redis_key
    format(::Redis::Alfred::WHATSAPP_WEB_PENDING_MESSAGE_STATUS, inbox_id: inbox_id, source_id: source_id)
  end
end
