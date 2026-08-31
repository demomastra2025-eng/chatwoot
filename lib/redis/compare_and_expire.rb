class Redis::CompareAndExpire
  SCRIPT = <<~LUA.freeze
    if redis.call('get', KEYS[1]) == ARGV[1] then
      return redis.call('expire', KEYS[1], ARGV[2])
    end
    return 0
  LUA

  def self.call(connection_pool, key, value, seconds)
    connection_pool.with do |connection|
      if defined?(::MockRedis) && connection.redis.instance_of?(::MockRedis)
        next 0 unless connection.get(key) == value

        next connection.expire(key, seconds)
      end

      connection.call_with_namespace(:eval, SCRIPT, keys: [key], argv: [value, seconds])
    end
  end
end
