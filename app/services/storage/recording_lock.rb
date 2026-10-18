# frozen_string_literal: true

require 'securerandom'
require 'timeout'
require 'zlib'

# Serializes mutations of a tenant recording across web and job workers without pinning PostgreSQL sessions.
module Storage::RecordingLock
  LOCK_NAMESPACE = 1_398_031_876
  LOCK_TTL_SECONDS = 300
  LOCK_WAIT_TIMEOUT_SECONDS = 60
  LOCK_POLL_INTERVAL_SECONDS = 0.02

  module_function

  def synchronize(account_id:, storage_keys:, &)
    keys = Array(storage_keys).compact.reject(&:blank?).map do |key|
      Storage::RecordingPaths.canonical_lock_identity(key, account_id: account_id)
    end.uniq.sort
    synchronize_keys(account_id.to_i, keys, 0, &)
  end

  def synchronize_keys(account_id, keys, index, &)
    return yield if index >= keys.length

    lock_id = Zlib.crc32("#{account_id}:#{keys[index]}") & 0x7fff_ffff
    redis_key = "storage:recording_lock:#{LOCK_NAMESPACE}:#{account_id}:#{lock_id}"
    token = "#{Process.pid}:#{Thread.current.object_id}:#{SecureRandom.hex(8)}"
    acquire_redis_lock!(redis_key, token)
    begin
      synchronize_keys(account_id, keys, index + 1, &)
    ensure
      Redis::Alfred.delete_if_value(redis_key, token)
    end
  end
  private_class_method :synchronize_keys

  def acquire_redis_lock!(redis_key, token)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_WAIT_TIMEOUT_SECONDS
    loop do
      return true if Redis::Alfred.set(redis_key, token, nx: true, ex: LOCK_TTL_SECONDS)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Timeout::Error, "Timed out acquiring recording lock #{redis_key}"
      end

      sleep(LOCK_POLL_INTERVAL_SECONDS)
    end
  end
  private_class_method :acquire_redis_lock!
end
