class Integrations::Medelement::DeltaMissAudit
  AuditUnavailableError = Class.new(StandardError)
  SEEN_RETENTION = 7.days
  STEPS_MINUTES = Integrations::Medelement::Configuration::ADAPTIVE_FULL_SWEEP_STEPS_MINUTES
  BACKOFF_CURSOR_NAME = Integrations::Medelement::Configuration::FULL_SWEEP_BACKOFF_CURSOR_NAME
  DEFAULT_SWEEP_SECONDS = Integrations::Medelement::Configuration::RECEPTIONS_SYNC_INTERVAL_MINUTES * 60
  DELTA_HEALTH_MAX_AGE = 5.minutes

  def initialize(hook:)
    @hook = hook
    @configuration = Integrations::Medelement::Configuration.new(hook: hook)
  end

  def record_change!(reception_code:, change_marker:, kind:, changed_fields:, full_sweep_run: nil)
    return unless configuration.incremental_receptions_enabled?

    cursor = cursor_scope.first
    return unless cursor&.last_success_at
    return if seen_scope.exists?(reception_code: reception_code, change_marker: change_marker)

    now = Time.current
    Integrations::Medelement::DeltaMissCandidate.create_or_find_by!(
      hook: hook, reception_code: reception_code, kind: kind, change_marker: change_marker
    ) do |candidate|
      candidate.detected_at = now
      candidate.full_sweep_run = full_sweep_run
      candidate.changed_fields = changed_fields.sort
      candidate.delta_cursor_age_seconds = (now - cursor.value).to_i if cursor.value
    end
  end

  def resolve_candidates!(poll_completed_at:)
    grace = 2 * configuration.incremental_receptions_interval_seconds
    unexplained = 0
    candidates.where('detected_at <= ?', poll_completed_at - grace.seconds).find_each do |candidate|
      unexplained += 1 if candidate_missed?(candidate) && record_miss!(candidate) == 'unexplained'
      candidate.destroy!
    end
    prune_seen!
    unexplained
  end

  def record_poll_error!(error)
    return unless configuration.incremental_receptions_enabled?

    now = Time.current
    code = poll_error_code(error)
    miss = Integrations::Medelement::DeltaMiss.find_or_initialize_by(
      hook: hook, reception_code: "poll_error:#{code}", kind: 'poll_error', change_marker: now.utc.strftime('%Y-%m-%dT%H')
    )
    miss.update!(detected_at: now, classification: 'provider_error', changed_fields: poll_error_fields(error, code))
    reset_full_sweep_backoff!(reason: code)
    miss
  end

  def record_full_sweep_result!
    return unless configuration.incremental_receptions_enabled?

    unexplained = resolve_candidates!(poll_completed_at: Time.current)
    return step_up_full_sweep_backoff! if unexplained.zero? && delta_healthy_for_step_up?

    reset_full_sweep_backoff!(reason: 'delta_unhealthy') unless delta_cursor_healthy?
  end

  def reset_full_sweep_backoff!(reason: nil)
    cursor = Integrations::Medelement::SyncCursor.find_by(hook_id: hook.id, name: BACKOFF_CURSOR_NAME)
    return unless cursor

    previous = cursor.current_interval_seconds || DEFAULT_SWEEP_SECONDS
    cursor.update!(current_interval_seconds: DEFAULT_SWEEP_SECONDS, last_poll_at: Time.current)
    return if previous == DEFAULT_SWEEP_SECONDS

    sync_cron_schedule!
    Rails.logger.warn(
      "[MEDELEMENT::DELTA_BACKOFF] hook=#{hook.id} reset_to_seconds=#{DEFAULT_SWEEP_SECONDS} reason=#{reason}"
    )
  end

  def prune_seen!
    seen_scope.where(processed_at: ...SEEN_RETENTION.ago).delete_all
  end

  private

  attr_reader :hook, :configuration

  def cursor_scope
    Integrations::Medelement::SyncCursor.where(hook_id: hook.id, name: 'receptions_delta')
  end

  def candidates
    Integrations::Medelement::DeltaMissCandidate.where(hook_id: hook.id)
  end

  def seen_scope
    Integrations::Medelement::DeltaSeenReception.where(hook_id: hook.id)
  end

  def candidate_missed?(candidate)
    !seen_scope.exists?(reception_code: candidate.reception_code, change_marker: candidate.change_marker)
  end

  def delta_cursor_healthy?
    cursor = cursor_scope.first
    return false unless cursor&.last_success_at
    return false if cursor.last_poll_at && cursor.last_poll_at > cursor.last_success_at

    cursor.last_success_at >= DELTA_HEALTH_MAX_AGE.ago
  end

  def delta_healthy_for_step_up?
    delta_cursor_healthy? && candidates.none?
  end

  def step_up_full_sweep_backoff!
    now = Time.current
    cursor = Integrations::Medelement::SyncCursor.find_or_initialize_by(hook: hook, name: BACKOFF_CURSOR_NAME)
    previous = cursor.current_interval_seconds || DEFAULT_SWEEP_SECONDS
    next_seconds = next_step_minutes(previous / 60) * 60
    cursor.update!(current_interval_seconds: next_seconds, value: now, last_poll_at: now, last_success_at: now)
    return if previous == next_seconds

    sync_cron_schedule!
    Rails.logger.info("[MEDELEMENT::DELTA_BACKOFF] hook=#{hook.id} stepped_up_seconds=#{next_seconds}")
  end

  def next_step_minutes(current_minutes)
    STEPS_MINUTES.find { |step| step > current_minutes } || STEPS_MINUTES.last
  end

  def sync_cron_schedule!
    Integrations::Medelement::CronScheduleService.new(hook: hook).sync!
  end

  def poll_error_code(error)
    return "http_#{error.status}" if error.respond_to?(:status) && error.status.present?

    error.class.name.demodulize.underscore
  end

  def poll_error_fields(error, code)
    provider_msg = error.provider_message if error.respond_to?(:provider_message)
    [
      code,
      error.class.name,
      Integrations::Medelement::ErrorSanitizer.sanitize(provider_msg.presence || error.message.to_s.squish)
    ].compact_blank
  end

  def record_miss!(candidate)
    classification = own_api_change?(candidate) ? 'own_api_change' : 'unexplained'
    miss = Integrations::Medelement::DeltaMiss.create_or_find_by!(
      hook: hook, reception_code: candidate.reception_code, kind: candidate.kind,
      change_marker: candidate.change_marker
    ) do |record|
      record.detected_at = candidate.detected_at
      record.full_sweep_run = candidate.full_sweep_run
      record.delta_cursor_age_seconds = candidate.delta_cursor_age_seconds
      record.changed_fields = candidate.changed_fields
      record.classification = classification
    end
    handle_unexplained_miss!(miss) if classification == 'unexplained'
    classification
  end

  def handle_unexplained_miss!(miss)
    reset_full_sweep_backoff!(reason: 'delta_miss')
    log_unexplained_miss(miss) if miss.previously_new_record?
  end

  def own_api_change?(candidate)
    Integrations::Medelement::ProviderCommand.exists?(
      hook_id: hook.id, provider_reception_code: candidate.reception_code,
      operation: %w[create_reception move_reception remove_reception], status: 'succeeded',
      updated_at: (candidate.detected_at - 30.minutes)..candidate.detected_at
    )
  end

  def log_unexplained_miss(miss)
    key = "medelement-delta-miss-log:#{hook.id}"
    return unless Rails.cache.write(key, true, expires_in: 1.hour, unless_exist: true)

    Rails.logger.error(
      "[MEDELEMENT::DELTA_MISS] hook=#{hook.id} kind=#{miss.kind} " \
      "code_digest=#{Integrations::Medelement::ErrorSanitizer.digest(miss.reception_code)}"
    )
  end
end
