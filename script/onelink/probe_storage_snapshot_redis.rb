# frozen_string_literal: true

# Service-free probe. Run only against the isolated fixture Redis with its URL explicitly supplied.
# No Rails boot, application connection pool, global keys, scans or flushes are used.
require 'json'
require 'securerandom'
require 'redis'
require 'redis-namespace'
require 'connection_pool'
require_relative '../../lib/redis/storage_snapshot_publish'

module StorageSnapshotRealRedisProbe
  class Failure < StandardError; end

  module_function

  def check(condition, description)
    raise Failure, description unless condition

    @checks = (@checks || 0) + 1
  end

  def values(bytes, generation: '1', lease: 'worker-a', reconciliation: true)
    payload = JSON.generate(recording_total_bytes: bytes)
    [generation, lease, payload, payload, reconciliation ? payload : '', '86400', bytes.to_s, '604800']
  end

  def run
    @checks = 0
    redis_url = ENV.fetch('STORAGE_SNAPSHOT_PROBE_REDIS_URL')
    namespace = "codex-storage-snapshot-probe:#{SecureRandom.hex(12)}"
    keys = %w[generation lease overview heavy reconciliation last_good]
    pool = ConnectionPool.new(size: 1, timeout: 2) do
      Redis::Namespace.new(namespace, redis: Redis.new(url: redis_url, timeout: 2))
    end
    pool.with do |connection|
      check(connection.redis.instance_of?(Redis), 'probe must use real Redis')
      connection.set(keys[0], '1')
      connection.set(keys[1], 'worker-a', ex: 300)
    end

    check(Redis::StorageSnapshotPublish.call(pool, keys, values(10, generation: '0')) == 0, 'generation mismatch must reject')
    check(Redis::StorageSnapshotPublish.call(pool, keys, values(10, lease: 'worker-b')) == 0, 'lease mismatch must reject')
    pool.with { |connection| check(connection.mget(*keys.drop(2)) == [nil] * 4, 'rejected workers must write no payloads') }

    check(Redis::StorageSnapshotPublish.call(pool, keys, values(10)) == 1, 'matching worker must publish')
    pool.with do |connection|
      payload = JSON.generate(recording_total_bytes: 10)
      check(connection.mget(*keys) == ['1', 'worker-a', payload, payload, payload, '10'], 'all six namespaced keys must agree')
      check(connection.redis.mget(*keys.map { |key| "#{namespace}:#{key}" }) == connection.mget(*keys), 'EVAL must honor Redis::Namespace')
      check(connection.ttl(keys[4]).between?(86_395, 86_400), 'reconciliation must expire after one day')
      check(connection.ttl(keys[5]).between?(604_795, 604_800), 'last good total must expire after seven days')
      check(connection.ttl(keys[2]) == -1 && connection.ttl(keys[3]) == -1, 'overview and compatibility payloads must persist')
    end

    check(Redis::StorageSnapshotPublish.call(pool, keys, values(15, reconciliation: false)) == 1, 'cached refresh must publish')
    pool.with do |connection|
      check(connection.get(keys[4]) == JSON.generate(recording_total_bytes: 10), 'empty reconciliation argument must preserve the physical audit')
      connection.set(keys[1], 'worker-b', ex: 300)
    end
    check(Redis::StorageSnapshotPublish.call(pool, keys, values(20, lease: 'worker-b')) == 1, 'successor worker must publish')
    latest = pool.with { |connection| connection.mget(*keys) }
    check(Redis::StorageSnapshotPublish.call(pool, keys, values(99)) == 0, 'late worker must be fenced by the new lease')
    pool.with { |connection| check(connection.mget(*keys) == latest, 'late worker must preserve all successor values') }
    pool.with { |connection| connection.set(keys[0], '2') }
    check(Redis::StorageSnapshotPublish.call(pool, keys, values(99, lease: 'worker-b')) == 0, 'new generation must fence old calculations')
    pool.with { |connection| check(connection.get(keys[5]) == '20', 'generation rejection must preserve last good total') }
    puts "real Redis storage snapshot: #{@checks} checks passed"
  ensure
    if pool
      pool.with { |connection| connection.del(*keys) }
      pool.shutdown { |connection| connection.redis.close }
    end
  end
end

begin
  StorageSnapshotRealRedisProbe.run
rescue StorageSnapshotRealRedisProbe::Failure => e
  warn "real Redis storage snapshot failed: #{e.message}"
  exit 1
rescue StandardError => e
  warn "real Redis storage snapshot failed: #{e.class}"
  exit 1
end
