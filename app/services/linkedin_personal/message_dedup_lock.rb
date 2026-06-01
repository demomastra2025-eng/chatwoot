class LinkedinPersonal::MessageDedupLock
  KEY_PREFIX = Redis::RedisKeys::MESSAGE_SOURCE_KEY
  DEFAULT_TTL = 1.day.to_i

  def initialize(inbox_id:, source_id:, ttl: DEFAULT_TTL)
    scoped_source_id = "linkedin_personal:#{inbox_id}:#{source_id}"
    @key = format(KEY_PREFIX, id: scoped_source_id)
    @ttl = ttl
  end

  def acquire!
    ::Redis::Alfred.set(@key, true, nx: true, ex: @ttl)
  end
end
