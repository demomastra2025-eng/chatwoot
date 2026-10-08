# frozen_string_literal: true

# Publish overview, compatibility rows, physical reconciliation and last good total for the current generation/worker.
class Redis::StorageSnapshotPublish
  SCRIPT = <<~LUA.freeze
    if (redis.call('get', KEYS[1]) or '0') ~= ARGV[1] then return 0 end
    if ARGV[2] ~= '' and redis.call('get', KEYS[2]) ~= ARGV[2] then return 0 end
    redis.call('set', KEYS[3], ARGV[3])
    redis.call('set', KEYS[4], ARGV[4])
    if ARGV[5] ~= '' then redis.call('set', KEYS[5], ARGV[5], 'EX', ARGV[6]) end
    redis.call('set', KEYS[6], ARGV[7], 'EX', ARGV[8])
    return 1
  LUA

  def self.call(connection_pool, keys, values)
    connection_pool.with do |connection|
      next publish_mock(connection, keys, values) if defined?(::MockRedis) && connection.redis.instance_of?(::MockRedis)

      connection.call_with_namespace(:eval, SCRIPT, keys: keys, argv: values)
    end
  end

  def self.publish_mock(connection, keys, values)
    return 0 unless (connection.get(keys[0]) || '0') == values[0]
    return 0 if values[1].present? && connection.get(keys[1]) != values[1]

    connection.set(keys[2], values[2])
    connection.set(keys[3], values[3])
    connection.set(keys[4], values[4], ex: values[5].to_i) if values[4].present?
    connection.set(keys[5], values[6], ex: values[7].to_i)
    1
  end
  private_class_method :publish_mock
end
