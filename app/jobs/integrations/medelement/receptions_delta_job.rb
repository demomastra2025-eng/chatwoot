class Integrations::Medelement::ReceptionsDeltaJob < ApplicationJob
  queue_as :medelement_sync

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
      run_poll(hook, configuration, -> { renew!(delta_lock, delta_key) })
    ensure
      delta_lock.unlock(delta_key)
      schedule_next(hook, configuration)
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

  def renew!(delta_lock, delta_key)
    return if delta_lock.renew(delta_key, LOCK_TIMEOUT)

    raise 'Medelement delta lock lease lost'
  end

  def run_poll(hook, configuration, renew_locks)
    Integrations::Medelement::ReceptionsDeltaService.new(
      hook: hook, configuration: configuration, renew_locks: renew_locks
    ).perform
  rescue Integrations::Medelement::ReceptionsDeltaService::IntegrationChangedError
    # Abort without advancing the cursor after a disable/configuration change.
    nil
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    record_error!(hook, configuration, e)
  end

  def record_error!(hook, configuration, error)
    cursor = Integrations::Medelement::SyncCursor.find_or_create_by!(hook: hook, name: 'receptions_delta')
    interval = cursor.current_interval_seconds || configuration.incremental_receptions_interval_seconds
    interval = [interval * 2, MAX_BACKOFF_SECONDS].min if retryable?(error)
    cursor.update!(current_interval_seconds: interval, last_poll_at: Time.current)
    Integrations::Medelement::DeltaMissAudit.new(hook: hook).record_poll_error!(error)
    Rails.logger.warn(
      "[MEDELEMENT::DELTA] hook=#{hook.id} error=#{error.class.name} " \
      "status=#{error.respond_to?(:status) ? error.status : 'none'} interval=#{interval}"
    )
  end

  def retryable?(error)
    error.is_a?(Integrations::Medelement::Client::ApiError) && error.retryable?
  end

  def schedule_next(hook, configuration)
    return unless configuration.incremental_receptions_interval_seconds < 60

    fresh_configuration = Integrations::Medelement::Configuration.new(hook: hook.reload)
    return unless enabled?(hook, fresh_configuration)
    return if fresh_configuration.off_hours?

    cursor = Integrations::Medelement::SyncCursor.find_by(hook_id: hook.id, name: 'receptions_delta')
    interval = cursor&.current_interval_seconds || fresh_configuration.incremental_receptions_interval_seconds
    self.class.set(wait: interval + Kernel.rand(0..3)).perform_later(hook.id)
  end
end
