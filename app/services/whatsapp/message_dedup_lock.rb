# Atomic dedup lock for WhatsApp incoming messages.
#
# Meta can deliver the same webhook event multiple times. This lock uses
# Redis SET NX EX to ensure only one worker processes a given source_id per inbox.
class Whatsapp::MessageDedupLock
  KEY_PREFIX = Redis::RedisKeys::MESSAGE_SOURCE_KEY
  DEFAULT_TTL = 5.minutes.to_i

  def initialize(inbox_id:, source_id:, ttl: DEFAULT_TTL)
    scoped_source_id = "whatsapp:#{inbox_id}:#{source_id}"
    @key = format(KEY_PREFIX, id: scoped_source_id)
    @ttl = ttl
    @token = SecureRandom.uuid
  end

  # Returns true when the lock is acquired (caller should proceed).
  # Returns false when another worker already holds the lock.
  def acquire!
    ::Redis::Alfred.set(@key, @token, nx: true, ex: @ttl)
  end

  def release!
    ::Redis::Alfred.delete_if_value(@key, @token) == 1
  end
end
