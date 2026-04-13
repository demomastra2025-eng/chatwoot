# Atomic dedup lock for Telegram Personal incoming messages.
#
# Telethon callbacks may be retried or delivered concurrently while Sidekiq
# is already processing the same external message. This lock keeps processing
# idempotent across workers.
class TelegramPersonal::MessageDedupLock
  KEY_PREFIX = Redis::RedisKeys::MESSAGE_SOURCE_KEY
  DEFAULT_TTL = 1.day.to_i

  def initialize(inbox_id:, source_id:, ttl: DEFAULT_TTL)
    scoped_source_id = "telegram_personal:#{inbox_id}:#{source_id}"
    @key = format(KEY_PREFIX, id: scoped_source_id)
    @ttl = ttl
  end

  def acquire!
    ::Redis::Alfred.set(@key, true, nx: true, ex: @ttl)
  end
end
