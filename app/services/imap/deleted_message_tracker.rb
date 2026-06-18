require 'digest'

class Imap::DeletedMessageTracker
  include MailboxSanitizer

  TTL = 2.days.to_i

  pattr_initialize [:inbox!]

  def record(source_ids)
    return unless inbox.email?

    source_ids = source_ids.map { |source_id| sanitize_mailbox_value(source_id) }.compact_blank.uniq
    keys = source_ids.map { |source_id| redis_key(source_id) }
    return if keys.blank?

    keys.each { |key| Redis::Alfred.set(key, true, ex: TTL) }
  end

  def deleted?(source_id)
    source_id = sanitize_mailbox_value(source_id)
    return false if source_id.blank?

    Redis::Alfred.exists?(redis_key(source_id))
  end

  private

  def redis_key(source_id)
    format(Redis::RedisKeys::IMAP_DELETED_MESSAGE, inbox_id: inbox.id, message_id_digest: Digest::SHA256.hexdigest(source_id))
  end
end
