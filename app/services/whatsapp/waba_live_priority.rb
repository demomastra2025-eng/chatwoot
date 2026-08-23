require 'digest'

class Whatsapp::WabaLivePriority
  WAITER_TTL = 5.minutes

  class LiveTrafficPendingError < StandardError; end

  class << self
    def with_waiters(waba_ids, waiter_id:)
      release_waiters = true
      waiters = normalized_waba_ids(waba_ids).map { |waba_id| new(waba_id, waiter_id: waiter_id) }
      waiters.each(&:register!)
      yield
    rescue Whatsapp::WabaLock::LockAcquisitionError
      release_waiters = false
      raise
    ensure
      waiters&.reverse_each(&:release!) if release_waiters
    end

    def waiting?(waba_id)
      new(waba_id).waiting?
    end

    def ensure_clear!(waba_id)
      return unless waiting?(waba_id)

      raise LiveTrafficPendingError, 'Live WhatsApp traffic is waiting'
    end

    private

    def normalized_waba_ids(waba_ids)
      Array(waba_ids).compact_blank.map(&:to_s).uniq.sort
    end
  end

  def initialize(waba_id, waiter_id: SecureRandom.uuid)
    raise ArgumentError, 'WABA ID is required' if waba_id.blank?
    raise ArgumentError, 'Waiter ID is required' if waiter_id.blank?

    @waba_id = waba_id.to_s
    @waiter_id = waiter_id.to_s
  end

  def register!
    Redis::Alfred.zadd(redis_key, expires_at, @waiter_id)
    Redis::Alfred.expire(redis_key, WAITER_TTL.to_i)
  end

  def release!
    Redis::Alfred.zrem(redis_key, @waiter_id)
  end

  def waiting?
    now = Time.current.to_f
    Redis::Alfred.zremrangebyscore(redis_key, '-inf', now)
    Redis::Alfred.zcount(redis_key, now, '+inf').positive?
  end

  private

  def expires_at
    Time.current.to_f + WAITER_TTL.to_i
  end

  def redis_key
    @redis_key ||= "whatsapp:waba-live-priority:#{Digest::SHA256.hexdigest(@waba_id).first(32)}"
  end
end
