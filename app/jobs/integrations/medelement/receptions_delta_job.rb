class Integrations::Medelement::ReceptionsDeltaJob < ApplicationJob
  queue_as :default

  LOCK_TIMEOUT = 30.minutes
  MAX_BACKOFF_SECONDS = 5.minutes.to_i

  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id)
    hook = Integrations::Hook.find_by!(id: hook_id, app_id: 'medelement')
    configuration = Integrations::Medelement::Configuration.new(hook: hook)
    return unless enabled?(hook, configuration)
    return unless due?(hook, configuration)

    delta_key = "MEDELEMENT_RECEPTIONS_DELTA_MUTEX::#{hook.id}"
    delta_lock = Redis::LockManager.new
    return unless delta_lock.lock(delta_key, LOCK_TIMEOUT)

    begin
      poll_under_full_sync_lock(hook, configuration, delta_lock, delta_key)
    ensure
      delta_lock.unlock(delta_key)
    end
  end

  private

  def enabled?(hook, configuration)
    hook.enabled? && hook.feature_allowed? && configuration.sync_receptions? &&
      configuration.incremental_receptions_enabled?
  end

  def due?(hook, configuration)
    cursor = Integrations::Medelement::SyncCursor.find_by(hook_id: hook.id, name: 'receptions_delta')
    return true unless cursor&.last_poll_at

    interval = cursor.current_interval_seconds || configuration.incremental_receptions_interval_seconds
    cursor.last_poll_at + interval.seconds <= Time.current
  end

  def poll_under_full_sync_lock(hook, configuration, delta_lock, delta_key)
    full_key = format(::Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: hook.account_id)
    full_lock = Redis::LockManager.new
    if full_lock.lock(full_key, LOCK_TIMEOUT)
      begin
        run_poll(hook, configuration, -> { renew!(delta_lock, delta_key, full_lock, full_key) })
      ensure
        full_lock.unlock(full_key)
      end
    else
      Rails.logger.info("[MEDELEMENT::DELTA] hook=#{hook.id} full_sync_busy=true")
      pause_for_full_sync!(hook)
    end
  ensure
    schedule_next(hook, configuration)
  end

  def renew!(delta_lock, delta_key, full_lock, full_key)
    return if delta_lock.renew(delta_key, LOCK_TIMEOUT) && full_lock.renew(full_key, LOCK_TIMEOUT)

    raise 'Medelement delta lock lease lost'
  end

  def run_poll(hook, configuration, renew_locks)
    Integrations::Medelement::ReceptionsDeltaService.new(
      hook: hook, configuration: configuration, renew_locks: renew_locks
    ).perform
  rescue StandardError => e
    record_error!(hook, configuration, e)
  end

  def record_error!(hook, configuration, error)
    cursor = Integrations::Medelement::SyncCursor.create_or_find_by!(hook: hook, name: 'receptions_delta')
    interval = cursor.current_interval_seconds || configuration.incremental_receptions_interval_seconds
    interval = [interval * 2, MAX_BACKOFF_SECONDS].min if retryable?(error)
    cursor.update!(current_interval_seconds: interval, last_poll_at: Time.current)
    Rails.logger.warn(
      "[MEDELEMENT::DELTA] hook=#{hook.id} error=#{error.class.name} " \
      "status=#{error.respond_to?(:status) ? error.status : 'none'} interval=#{interval}"
    )
  end

  def pause_for_full_sync!(hook)
    cursor = Integrations::Medelement::SyncCursor.create_or_find_by!(hook: hook, name: 'receptions_delta')
    cursor.update!(current_interval_seconds: MAX_BACKOFF_SECONDS, last_poll_at: Time.current)
  end

  def retryable?(error)
    error.is_a?(Integrations::Medelement::Client::ApiError) && error.retryable?
  end

  def schedule_next(hook, configuration)
    return unless configuration.incremental_receptions_interval_seconds < 60
    return unless enabled?(hook.reload, Integrations::Medelement::Configuration.new(hook: hook))

    cursor = Integrations::Medelement::SyncCursor.find_by(hook_id: hook.id, name: 'receptions_delta')
    interval = cursor&.current_interval_seconds || configuration.incremental_receptions_interval_seconds
    self.class.set(wait: interval + Kernel.rand(0..3)).perform_later(hook.id)
  end
end
