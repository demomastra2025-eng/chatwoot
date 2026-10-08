class Integrations::Medelement::SyncRunHeartbeat
  INTERVAL = 5.minutes
  LockLeaseLostError = Class.new(StandardError)

  def initialize(sync_run, interval: INTERVAL, renew_lock: nil, worker_token: nil)
    @sync_run = sync_run
    @interval = interval
    @renew_lock = renew_lock
    @worker_token = worker_token
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @stopped = false
  end

  def around
    @owner_thread = Thread.current
    start
    yield
  ensure
    stop
  end

  private

  attr_reader :condition, :heartbeat_thread, :interval, :mutex, :owner_thread, :renew_lock, :sync_run, :worker_token

  def start
    @heartbeat_thread = Thread.new do
      Thread.current.report_on_exception = false
      loop do
        break if wait_until_next_heartbeat

        heartbeat
      end
    end
  end

  def wait_until_next_heartbeat
    mutex.synchronize do
      condition.wait(mutex, interval) unless @stopped
      @stopped
    end
  end

  def heartbeat
    if renew_lock && !renew_lock.call
      owner_thread.raise(LockLeaseLostError, 'Medelement sync lock lease was lost')
      return
    end

    Rails.application.executor.wrap do
      worker_token ? sync_run.heartbeat!(worker_token: worker_token) : sync_run.heartbeat!
    end
  rescue StandardError => e
    Rails.logger.warn("Medelement sync heartbeat failed: #{e.class}")
  end

  def stop
    mutex.synchronize do
      @stopped = true
      condition.broadcast
    end
    heartbeat_thread&.join
  end
end
