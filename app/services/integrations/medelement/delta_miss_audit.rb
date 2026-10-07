class Integrations::Medelement::DeltaMissAudit
  AuditUnavailableError = Class.new(StandardError)
  SEEN_RETENTION = 7.days

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
    candidates.where('detected_at <= ?', poll_completed_at - grace.seconds).find_each do |candidate|
      record_miss!(candidate) unless seen_scope.exists?(
        reception_code: candidate.reception_code, change_marker: candidate.change_marker
      )
      candidate.destroy!
    end
    prune_seen!
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
    log_unexplained_miss(miss) if miss.previously_new_record? && classification == 'unexplained'
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
