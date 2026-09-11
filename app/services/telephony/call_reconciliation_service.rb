class Telephony::CallReconciliationService
  DEFAULT_GENERIC_PRE_ANSWER_STALE_AFTER = 1.hour
  DEFAULT_AI_PRE_ANSWER_STALE_AFTER = 2.minutes
  DEFAULT_RUNTIME_LEASE_STALE_AFTER = 90.seconds
  DEFAULT_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER = 60.seconds
  DEFAULT_SIPUNI_PROVIDER_RINGING_STALE_AFTER = 5.minutes
  DEFAULT_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER = 1.hour
  DEFAULT_NATIVE_SIP_PRE_ANSWER_STALE_AFTER = 2.minutes
  DEFAULT_NATIVE_SIP_IN_PROGRESS_STALE_AFTER = 1.hour
  DEFAULT_NATIVE_SIP_LOCAL_OUTBOUND_MISSING_AFTER = 60.seconds
  FAILED_RECONCILIATION_RETRY_BASE_DELAY = 5.minutes
  MAX_FAILED_RECONCILIATION_RETRIES = 5

  SOURCE_SIPUNI_LOCAL_OUTBOUND_RECONCILIATION = 'sipuni_local_outbound_reconciliation'.freeze
  SOURCE_SIPUNI_PROVIDER_RECONCILIATION = 'sipuni_provider_reconciliation'.freeze
  SOURCE_NATIVE_SIP_RECONCILIATION = 'native_sip_reconciliation'.freeze
  SOURCE_GENERIC_PRE_ANSWER_RECONCILIATION = 'generic_pre_answer_reconciliation'.freeze
  SOURCE_AI_PRE_ANSWER_RECONCILIATION = 'ai_pre_answer_reconciliation'.freeze
  SOURCE_MAX_CALL_DURATION_RECONCILIATION = 'max_call_duration_reconciliation'.freeze
  SOURCE_RUNTIME_LEASE_RECONCILIATION = 'runtime_lease_reconciliation'.freeze
  RETRYABLE_RECONCILIATION_SOURCES = [
    SOURCE_SIPUNI_LOCAL_OUTBOUND_RECONCILIATION,
    SOURCE_SIPUNI_PROVIDER_RECONCILIATION,
    SOURCE_NATIVE_SIP_RECONCILIATION,
    SOURCE_GENERIC_PRE_ANSWER_RECONCILIATION,
    SOURCE_AI_PRE_ANSWER_RECONCILIATION,
    SOURCE_MAX_CALL_DURATION_RECONCILIATION,
    SOURCE_RUNTIME_LEASE_RECONCILIATION
  ].freeze

  GENERIC_PRE_ANSWER_STATUSES = %w[created ringing connecting].freeze
  AI_PRE_ANSWER_STATUSES = %w[created ringing connecting].freeze
  SIPUNI_PRE_ANSWER_STATUSES = %w[created ringing connecting].freeze
  NATIVE_SIP_PRE_ANSWER_STATUSES = %w[created ringing connecting].freeze
  NATIVE_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel beeline wazo].freeze
  NATIVE_SIP_LOCAL_OUTBOUND_PROVIDERS = %w[asterisk_analog binotel beeline wazo].freeze

  STATUS_PROGRESS = {
    'created' => 0,
    'ringing' => 1,
    'connecting' => 2,
    'in_progress' => 3
  }.freeze
  ANSWER_EVIDENCE_EVENT_TYPES = %w[
    answer
    answered
    callee_answered
    call_status
    customer_answered
    dial_status
    ai_answered
    operator_answered
    transfer_answered
  ].freeze

  def initialize(account: nil, now: Time.current)
    @account = account
    @now = now
    @generic_pre_answer_stale_after = positive_env_duration(
      'TELEPHONY_GENERIC_PRE_ANSWER_STALE_AFTER_SECONDS',
      DEFAULT_GENERIC_PRE_ANSWER_STALE_AFTER
    )
    @ai_pre_answer_stale_after = positive_env_duration(
      'TELEPHONY_AI_PRE_ANSWER_STALE_AFTER_SECONDS',
      DEFAULT_AI_PRE_ANSWER_STALE_AFTER
    )
    @runtime_lease_stale_after = positive_env_duration(
      'TELEPHONY_RUNTIME_LEASE_STALE_AFTER_SECONDS',
      DEFAULT_RUNTIME_LEASE_STALE_AFTER
    )
    @sipuni_local_outbound_missing_after = positive_env_duration(
      'TELEPHONY_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS',
      DEFAULT_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER
    )
    @sipuni_provider_ringing_stale_after = positive_env_duration(
      'TELEPHONY_SIPUNI_PROVIDER_RINGING_STALE_AFTER_SECONDS',
      DEFAULT_SIPUNI_PROVIDER_RINGING_STALE_AFTER
    )
    @sipuni_provider_in_progress_stale_after = positive_env_duration(
      'TELEPHONY_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER_SECONDS',
      DEFAULT_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER
    )
    @native_sip_pre_answer_stale_after = positive_env_duration(
      'TELEPHONY_NATIVE_SIP_PRE_ANSWER_STALE_AFTER_SECONDS',
      DEFAULT_NATIVE_SIP_PRE_ANSWER_STALE_AFTER
    )
    @native_sip_in_progress_stale_after = positive_env_duration(
      'TELEPHONY_NATIVE_SIP_IN_PROGRESS_STALE_AFTER_SECONDS',
      DEFAULT_NATIVE_SIP_IN_PROGRESS_STALE_AFTER
    )
    @native_sip_local_outbound_missing_after = positive_env_duration(
      'TELEPHONY_NATIVE_SIP_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS',
      DEFAULT_NATIVE_SIP_LOCAL_OUTBOUND_MISSING_AFTER
    )
  end

  def perform
    result = { checked: 0, updated: 0, missing: 0, repaired: 0, errors: 0 }

    retry_failed_reconciliation_events!(result)
    repair_invalid_unanswered_actors!(result)
    reconcile_max_call_duration_sessions!(result)
    reconcile_expired_runtime_leases!(result)
    reconcile_missing_sipuni_local_outbound_sessions!(result)
    reconcile_missing_sipuni_provider_sessions!(result)
    reconcile_missing_native_sip_local_outbound_sessions!(result)
    reconcile_missing_native_sip_sessions!(result)
    reconcile_ai_pre_answer_sessions!(result)
    reconcile_generic_pre_answer_sessions!(result)

    result
  end

  private

  def repair_invalid_unanswered_actors!(result)
    scope = Telephony::CallSession.where(
      status: %w[missed no_answer rejected busy cancelled]
    ).where(answered_at: nil).where.not(answered_by: [nil, ''])
    scope = scope.where(account_id: account.id) if account.present?
    scope.find_each do |session|
      session.update!(answered_by: nil)
      result[:repaired] += 1
    end
  end

  JANUS_NATIVE_SIP_REF_SQL = NATIVE_SIP_PROVIDERS.map { |provider| "external_call_ref LIKE '#{provider}:janus:%'" }.join(' OR ').freeze
  NATIVE_SIP_LOCAL_REF_SQL = NATIVE_SIP_LOCAL_OUTBOUND_PROVIDERS.map { |provider| "external_call_ref LIKE '#{provider}:local:%'" }.join(' OR ').freeze
  AI_ROUTE_SCOPE_SQL = <<~SQL.squish.freeze
    COALESCE(
      metadata ->> 'route_action',
      metadata -> 'metadata' ->> 'route_action',
      metadata -> 'last_payload' -> 'metadata' ->> 'route_action',
      ''
    ) = 'ai'
  SQL
  SPECIFIC_RECONCILIATION_SCOPE_SQL = [
    "(provider = 'sipuni' AND direction = 'outbound' AND provider_call_sid IS NULL AND external_call_ref LIKE 'sipuni:local:%')",
    "(provider = 'sipuni' AND provider_call_sid IS NOT NULL)",
    "(#{JANUS_NATIVE_SIP_REF_SQL})",
    "(#{AI_ROUTE_SCOPE_SQL})",
    "(provider IN ('asterisk_analog', 'binotel', 'beeline') AND direction = 'outbound' " \
    "AND provider_call_sid IS NULL AND (#{NATIVE_SIP_LOCAL_REF_SQL}))"
  ].join(' OR ').freeze

  attr_reader :account, :now,
              :ai_pre_answer_stale_after, :generic_pre_answer_stale_after,
              :runtime_lease_stale_after,
              :native_sip_in_progress_stale_after, :native_sip_local_outbound_missing_after, :native_sip_pre_answer_stale_after,
              :sipuni_local_outbound_missing_after, :sipuni_provider_in_progress_stale_after, :sipuni_provider_ringing_stale_after

  def reconcile_max_call_duration_sessions!(result)
    scope = Telephony::CallSession.active
                                  .where.not(answered_at: nil)
                                  .where(answered_at: ..(now - Telephony::RoutingPolicy::MIN_MAX_CALL_DURATION_SECONDS))
                                  .includes(number_binding: :routing_policy)
    scope = scope.where(account_id: account.id) if account.present?

    scope.find_each do |session|
      routing_policy = session.number_binding&.routing_policy
      next if routing_policy.blank?

      limit_seconds = routing_policy.max_call_duration_seconds
      next if session.answered_at > now - limit_seconds

      result[:checked] += 1
      reconcile_answered_session!(
        session,
        result,
        source: SOURCE_MAX_CALL_DURATION_RECONCILIATION,
        reason: 'max_duration'
      )
    end
  end

  def reconcile_expired_runtime_leases!(result)
    scope = Telephony::CallSession.active
                                  .where(status: 'in_progress')
                                  .where("metadata -> 'runtime_lease' IS NOT NULL")
    scope = scope.where(account_id: account.id) if account.present?

    scope.find_each do |session|
      next unless runtime_lease_expired?(session)

      result[:checked] += 1
      reconcile_answered_session!(
        session,
        result,
        source: SOURCE_RUNTIME_LEASE_RECONCILIATION,
        reason: 'runtime_lease_expired',
        guard: ->(locked_session) { runtime_lease_expired?(locked_session) }
      )
    end
  end

  def reconcile_answered_session!(session, result, source:, reason:, guard: nil)
    reconciled = false
    session.with_lock do
      session.reload
      next if session.terminal?
      next if guard.present? && !guard.call(session)

      session.update!(answered_reconciliation_attributes(session, source: source, reason: reason))
      reconciled = true
    end
    return unless reconciled

    apply_reconciliation_outcome!(result, reconciliation_outcome(session, 'completed', source: source))
  rescue StandardError
    result[:errors] += 1
  end

  def runtime_lease_expired?(session)
    heartbeat_at = session.metadata.to_h.dig('runtime_lease', 'heartbeat_at')
    return false if heartbeat_at.blank?

    Time.iso8601(heartbeat_at.to_s) <= now - runtime_lease_stale_after
  rescue ArgumentError
    false
  end

  def answered_reconciliation_attributes(session, source:, reason:)
    started_at = session.answered_at || session.started_at || now
    {
      status: 'completed',
      ended_at: now,
      ended_by: 'system',
      end_reason: reason,
      duration_seconds: [now.to_i - started_at.to_i, 0].max,
      last_event_at: [session.last_event_at, now].compact.max,
      metadata: session.metadata.to_h.deep_merge(
        'reconciliation' => { 'source' => source, 'reason' => reason, 'reconciled_at' => now.iso8601(3) }
      )
    }
  end

  def sipuni_local_outbound_missing_scope
    scope = Telephony::CallSession.active
                                  .where(provider: 'sipuni', direction: 'outbound', provider_call_sid: nil)
                                  .where("external_call_ref LIKE 'sipuni:local:%'")
    scope = scope.where(account_id: account.id) if account.present?
    reference_sql = 'COALESCE(last_event_at, started_at, updated_at, created_at)'
    scope.where(
      "(status IN (:pre_answer_statuses) AND answered_at IS NULL AND #{reference_sql} <= :pre_answer_before) OR " \
      "((status = :in_progress_status OR answered_at IS NOT NULL) AND #{reference_sql} <= :in_progress_before)",
      pre_answer_statuses: SIPUNI_PRE_ANSWER_STATUSES,
      pre_answer_before: now - sipuni_local_outbound_missing_after,
      in_progress_status: 'in_progress',
      in_progress_before: now - sipuni_provider_in_progress_stale_after
    )
  end

  def sipuni_provider_missing_scope
    scope = Telephony::CallSession.active
                                  .where(provider: 'sipuni')
                                  .where.not(provider_call_sid: nil)
    scope = scope.where(account_id: account.id) if account.present?

    reference_sql = 'COALESCE(last_event_at, started_at, updated_at, created_at)'
    scope.where(
      "(status IN (:pre_answer_statuses) AND answered_at IS NULL AND #{reference_sql} <= :pre_answer_before) OR " \
      "((status = :in_progress_status OR answered_at IS NOT NULL) AND #{reference_sql} <= :in_progress_before)",
      pre_answer_statuses: SIPUNI_PRE_ANSWER_STATUSES,
      pre_answer_before: now - sipuni_provider_ringing_stale_after,
      in_progress_status: 'in_progress',
      in_progress_before: now - sipuni_provider_in_progress_stale_after
    )
  end

  def native_sip_missing_scope
    scope = Telephony::CallSession.active
                                  .where(provider: NATIVE_SIP_PROVIDERS)
                                  .where(JANUS_NATIVE_SIP_REF_SQL)
    scope = scope.where(account_id: account.id) if account.present?

    reference_sql = 'COALESCE(last_event_at, started_at, updated_at, created_at)'
    scope.where(
      "(status IN (:pre_answer_statuses) AND answered_at IS NULL AND #{reference_sql} <= :pre_answer_before) OR " \
      "((status = :in_progress_status OR answered_at IS NOT NULL) AND #{reference_sql} <= :in_progress_before)",
      pre_answer_statuses: NATIVE_SIP_PRE_ANSWER_STATUSES,
      pre_answer_before: now - native_sip_pre_answer_stale_after,
      in_progress_status: 'in_progress',
      in_progress_before: now - native_sip_in_progress_stale_after
    )
  end

  def native_sip_local_outbound_missing_scope
    scope = Telephony::CallSession.active
                                  .where(provider: NATIVE_SIP_LOCAL_OUTBOUND_PROVIDERS, direction: 'outbound', provider_call_sid: nil)
    scope = scope.where(account_id: account.id) if account.present?
    local_ref_sql = NATIVE_SIP_LOCAL_OUTBOUND_PROVIDERS.map { |provider| "external_call_ref LIKE '#{provider}:local:%'" }.join(' OR ')
    reference_sql = 'COALESCE(last_event_at, started_at, updated_at, created_at)'
    scope.where(local_ref_sql).where(
      "(status IN (:pre_answer_statuses) AND answered_at IS NULL AND #{reference_sql} <= :pre_answer_before) OR " \
      "((status = :in_progress_status OR answered_at IS NOT NULL) AND #{reference_sql} <= :in_progress_before)",
      pre_answer_statuses: NATIVE_SIP_PRE_ANSWER_STATUSES,
      pre_answer_before: now - native_sip_local_outbound_missing_after,
      in_progress_status: 'in_progress',
      in_progress_before: now - native_sip_in_progress_stale_after
    )
  end

  def generic_pre_answer_missing_scope
    scope = Telephony::CallSession.active.where(status: GENERIC_PRE_ANSWER_STATUSES)
    scope = scope.where(account_id: account.id) if account.present?

    scope.where(
      'COALESCE(last_event_at, started_at, updated_at, created_at) <= ?',
      now - generic_pre_answer_stale_after
    ).where.not(SPECIFIC_RECONCILIATION_SCOPE_SQL)
  end

  def ai_pre_answer_missing_scope
    scope = Telephony::CallSession.active
                                  .where(status: AI_PRE_ANSWER_STATUSES)
                                  .where(AI_ROUTE_SCOPE_SQL)
    scope = scope.where(account_id: account.id) if account.present?

    scope.where(
      'COALESCE(last_event_at, started_at, updated_at, created_at) <= ?',
      now - ai_pre_answer_stale_after
    )
  end

  def reconcile_missing_sipuni_local_outbound_sessions!(result)
    sipuni_local_outbound_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      apply_reconciliation_outcome!(result, reconcile_missing_sipuni_local_outbound_session(session))
    end
  end

  def reconcile_missing_sipuni_provider_sessions!(result)
    sipuni_provider_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      apply_reconciliation_outcome!(result, reconcile_missing_sipuni_provider_session(session))
    end
  end

  def reconcile_missing_native_sip_sessions!(result)
    native_sip_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      apply_reconciliation_outcome!(result, reconcile_missing_native_sip_session(session))
    end
  end

  def reconcile_missing_native_sip_local_outbound_sessions!(result)
    native_sip_local_outbound_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      apply_reconciliation_outcome!(result, reconcile_missing_native_sip_local_outbound_session(session))
    end
  end

  def reconcile_generic_pre_answer_sessions!(result)
    generic_pre_answer_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      apply_reconciliation_outcome!(result, reconcile_generic_pre_answer_session(session))
    end
  end

  def reconcile_ai_pre_answer_sessions!(result)
    ai_pre_answer_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      apply_reconciliation_outcome!(result, reconcile_ai_pre_answer_session(session))
    end
  end

  def reconcile_missing_sipuni_local_outbound_session(session)
    target_status = nil
    reconciled = reconcile_stale_session(
      session,
      statuses: SIPUNI_PRE_ANSWER_STATUSES + ['in_progress'],
      stale_after: lambda do |locked_session|
        answered_session?(locked_session) ? sipuni_provider_in_progress_stale_after : sipuni_local_outbound_missing_after
      end,
      guard: method(:sipuni_local_outbound_session?)
    ) do |locked_session|
      ended_at = now
      target_status = answered_session?(locked_session) ? 'completed' : 'failed'
      locked_session.update!(
        status: target_status,
        ended_at: ended_at,
        ended_by: SOURCE_SIPUNI_LOCAL_OUTBOUND_RECONCILIATION,
        end_reason: target_status == 'completed' ? 'sipuni_local_outbound_missing_completed_call' : 'sipuni_provider_event_missing',
        duration_seconds: missing_duration_seconds(locked_session, ended_at, target_status),
        last_event_at: ended_at,
        metadata: missing_sipuni_local_outbound_metadata(locked_session, target_status),
        legs: append_missing_sipuni_local_outbound_leg_snapshot(locked_session, target_status)
      )
    end
    return false unless reconciled

    reconciliation_outcome(
      session,
      target_status,
      source: SOURCE_SIPUNI_LOCAL_OUTBOUND_RECONCILIATION
    )
  end

  def reconcile_missing_sipuni_provider_session(session)
    target_status = nil
    reconciled = reconcile_stale_session(
      session,
      statuses: SIPUNI_PRE_ANSWER_STATUSES + ['in_progress'],
      stale_after: lambda do |locked_session|
        answered_session?(locked_session) ? sipuni_provider_in_progress_stale_after : sipuni_provider_ringing_stale_after
      end,
      guard: method(:sipuni_provider_session?)
    ) do |locked_session|
      ended_at = now
      previous_status = locked_session.canonical_status
      target_status = missing_sipuni_provider_status(locked_session)
      locked_session.update!(
        status: target_status,
        ended_at: ended_at,
        ended_by: SOURCE_SIPUNI_PROVIDER_RECONCILIATION,
        end_reason: missing_sipuni_provider_end_reason(locked_session, target_status),
        duration_seconds: missing_duration_seconds(locked_session, ended_at, target_status),
        last_event_at: ended_at,
        metadata: missing_sipuni_provider_metadata(locked_session, target_status, previous_status),
        legs: append_missing_sipuni_provider_leg_snapshot(locked_session, target_status, previous_status)
      )
    end
    return false unless reconciled

    reconciliation_outcome(session, target_status, source: SOURCE_SIPUNI_PROVIDER_RECONCILIATION)
  end

  def reconcile_missing_native_sip_session(session)
    target_status = nil
    reconciled = reconcile_stale_session(
      session,
      statuses: NATIVE_SIP_PRE_ANSWER_STATUSES + ['in_progress'],
      stale_after: ->(locked_session) { answered_session?(locked_session) ? native_sip_in_progress_stale_after : native_sip_pre_answer_stale_after },
      guard: method(:native_sip_session?)
    ) do |locked_session|
      ended_at = now
      previous_status = locked_session.canonical_status
      target_status = missing_native_sip_status(locked_session)
      locked_session.update!(
        status: target_status,
        ended_at: ended_at,
        ended_by: SOURCE_NATIVE_SIP_RECONCILIATION,
        end_reason: missing_native_sip_end_reason(locked_session, target_status),
        duration_seconds: missing_duration_seconds(locked_session, ended_at, target_status),
        last_event_at: ended_at,
        metadata: missing_native_sip_metadata(locked_session, target_status, previous_status),
        legs: append_missing_native_sip_leg_snapshot(locked_session, target_status, previous_status)
      )
    end
    return false unless reconciled

    reconciliation_outcome(session, target_status, source: SOURCE_NATIVE_SIP_RECONCILIATION)
  end

  def reconcile_missing_native_sip_local_outbound_session(session)
    target_status = nil
    reconciled = reconcile_stale_session(
      session,
      statuses: NATIVE_SIP_PRE_ANSWER_STATUSES + ['in_progress'],
      stale_after: lambda do |locked_session|
        answered_session?(locked_session) ? native_sip_in_progress_stale_after : native_sip_local_outbound_missing_after
      end,
      guard: method(:native_sip_local_outbound_session?)
    ) do |locked_session|
      ended_at = now
      previous_status = locked_session.canonical_status
      target_status = missing_native_sip_status(locked_session)
      end_reason = if target_status == 'no_answer'
                     'native_sip_missing_outbound_no_answer'
                   else
                     missing_native_sip_end_reason(locked_session, target_status)
                   end
      locked_session.update!(
        status: target_status,
        ended_at: ended_at,
        ended_by: SOURCE_NATIVE_SIP_RECONCILIATION,
        end_reason: end_reason,
        duration_seconds: missing_duration_seconds(locked_session, ended_at, target_status),
        last_event_at: ended_at,
        metadata: missing_native_sip_metadata(locked_session, target_status, previous_status),
        legs: append_missing_native_sip_leg_snapshot(locked_session, target_status, previous_status)
      )
    end
    return false unless reconciled

    reconciliation_outcome(session, target_status, source: SOURCE_NATIVE_SIP_RECONCILIATION)
  end

  def reconcile_generic_pre_answer_session(session)
    target_status = nil
    reconciled = reconcile_stale_session(
      session,
      stale_after: generic_pre_answer_stale_after,
      statuses: GENERIC_PRE_ANSWER_STATUSES,
      guard: method(:generic_pre_answer_session?),
      skip: method(:generic_answer_evidence?)
    ) do |locked_session|
      previous_status = locked_session.canonical_status
      target_status = generic_pre_answer_status(locked_session)
      ended_at = now
      locked_session.update!(
        status: target_status,
        ended_at: ended_at,
        ended_by: SOURCE_GENERIC_PRE_ANSWER_RECONCILIATION,
        end_reason: generic_pre_answer_end_reason(locked_session, target_status),
        duration_seconds: missing_duration_seconds(locked_session, ended_at, target_status),
        last_event_at: ended_at,
        metadata: generic_pre_answer_metadata(locked_session, target_status, previous_status),
        legs: append_generic_pre_answer_leg_snapshot(locked_session, target_status, previous_status)
      )
    end
    return false unless reconciled

    reconciliation_outcome(session, target_status, source: SOURCE_GENERIC_PRE_ANSWER_RECONCILIATION)
  end

  def reconcile_ai_pre_answer_session(session)
    target_status = 'failed'
    reconciled = reconcile_stale_session(
      session,
      stale_after: ai_pre_answer_stale_after,
      statuses: AI_PRE_ANSWER_STATUSES,
      guard: method(:ai_pre_answer_session?),
      skip: method(:generic_answer_evidence?)
    ) do |locked_session|
      previous_status = locked_session.canonical_status
      ended_at = now
      locked_session.update!(
        status: target_status,
        ended_at: ended_at,
        ended_by: SOURCE_AI_PRE_ANSWER_RECONCILIATION,
        end_reason: 'ai_runtime_terminal_missing',
        duration_seconds: missing_duration_seconds(locked_session, ended_at, target_status),
        last_event_at: ended_at,
        metadata: ai_pre_answer_metadata(locked_session, target_status, previous_status),
        legs: append_ai_pre_answer_leg_snapshot(locked_session, target_status, previous_status)
      )
    end
    return false unless reconciled

    reconciliation_outcome(session, target_status, source: SOURCE_AI_PRE_ANSWER_RECONCILIATION)
  end

  def reconcile_stale_session(session, stale_after:, statuses:, guard: nil, skip: nil)
    reconciled = false
    session.with_lock do
      session.reload
      next if session.terminal?
      next if statuses.present? && statuses.exclude?(session.canonical_status)
      next if guard.present? && !guard.call(session)

      threshold = stale_after.respond_to?(:call) ? stale_after.call(session) : stale_after
      next unless stale_call_session?(session, threshold)
      next if skip.present? && skip.call(session)

      yield(session)
      reconciled = true
    end
    reconciled
  end

  def stale_call_session?(session, stale_after)
    reference_time = reconciliation_reference_time(session)
    reference_time.present? && reference_time <= now - stale_after
  end

  def reconciliation_reference_time(session)
    session.last_event_at || session.started_at || session.updated_at || session.created_at
  end

  def positive_env_duration(key, default)
    value = ENV[key].to_i
    value.positive? ? value.seconds : default
  end

  def apply_reconciliation_outcome!(result, outcome)
    return unless outcome

    result[:updated] += 1
    result[:errors] += 1 if outcome == :side_effect_failed
  end

  def reconciliation_outcome(session, status, source:)
    sync_reconciled_session!(session, status, source: source) ? true : :side_effect_failed
  end

  def sync_reconciled_session!(session, status, source: SOURCE_NATIVE_SIP_RECONCILIATION)
    return unless Telephony::CallSession::TERMINAL_STATUSES.include?(status)

    payload = reconciliation_event_payload(session, status, source: source)
    Telephony::EventsIngestionService.new(payload: payload).perform
    event = Telephony::Event.find_by(account_id: session.account_id, event_key: payload[:event_key])
    return false if event&.failed?

    true
  rescue StandardError => e
    Rails.logger.warn(
      event: 'telephony_call_reconciliation_side_effect_failed',
      account_id: session.account_id,
      call_ref: session.external_call_ref,
      status: status,
      error_class: e.class.name,
      error_message: e.message
    )
    false
  end

  def retry_failed_reconciliation_events!(result)
    scope = Telephony::Event.where(status: 'failed')
    scope = scope.where(account_id: account.id) if account.present?
    scope.where("payload -> 'metadata' ->> 'source' IN (?)", RETRYABLE_RECONCILIATION_SOURCES).find_each do |event|
      next unless failed_reconciliation_retry_due?(event)

      record_failed_reconciliation_retry!(event)
      Telephony::EventsIngestionService.new(payload: event.payload).perform
      event.reload
      next unless event.failed?

      result[:errors] += 1
      log_failed_reconciliation_retry(event)
    rescue StandardError => e
      result[:errors] += 1
      log_failed_reconciliation_retry(event, e)
    end
  end

  def failed_reconciliation_retry_due?(event)
    retry_count = failed_reconciliation_retry_count(event)
    return false if retry_count >= MAX_FAILED_RECONCILIATION_RETRIES
    return true if retry_count.zero?

    last_retry_at = event.payload.to_h.dig('metadata', 'reconciliation_last_retry_at')
    return true if last_retry_at.blank?

    now >= Time.zone.parse(last_retry_at) + failed_reconciliation_retry_delay(retry_count)
  rescue ArgumentError, TypeError
    true
  end

  def record_failed_reconciliation_retry!(event)
    retry_payload = event.payload.to_h.deep_dup
    retry_payload['metadata'] = retry_payload.fetch('metadata', {}).to_h
    retry_payload['metadata']['reconciliation_retry_count'] = failed_reconciliation_retry_count(event) + 1
    retry_payload['metadata']['reconciliation_last_retry_at'] = now.iso8601
    event.update!(payload: retry_payload)
  end

  def failed_reconciliation_retry_count(event)
    event.payload.to_h.dig('metadata', 'reconciliation_retry_count').to_i
  end

  def failed_reconciliation_retry_delay(retry_count)
    FAILED_RECONCILIATION_RETRY_BASE_DELAY * (2**(retry_count - 1))
  end

  def log_failed_reconciliation_retry(event, error = nil)
    Rails.logger.warn(
      event: 'telephony_call_reconciliation_retry_failed',
      event_id: event.id,
      account_id: event.account_id,
      call_ref: event.payload.to_h['call_ref'],
      retry_count: failed_reconciliation_retry_count(event),
      error_class: error&.class&.name || 'Telephony::EventFailed',
      error_message: error&.message || event.error_message
    )
  end

  def reconciliation_event_payload(session, status, source:)
    {
      account_id: session.account_id,
      inbox_id: session.inbox_id,
      call_ref: session.external_call_ref,
      event_key: reconciliation_event_key(session, status, source: source),
      event: reconciliation_event_type(status),
      status: status,
      direction: session.direction,
      from_number: session.from_number,
      to_number: session.to_number,
      started_at: session.started_at&.iso8601,
      answered_at: session.answered_at&.iso8601,
      ended_at: session.ended_at&.iso8601,
      ended_by: session.ended_by,
      end_reason: session.end_reason,
      duration: session.duration_seconds,
      metadata: {
        source: source
      }
    }.compact
  end

  def reconciliation_event_key(session, status, source:)
    ended_key = (session.ended_at || now).to_i
    "#{source}:#{session.account_id}:#{session.external_call_ref}:#{status}:#{ended_key}"
  end

  def reconciliation_event_type(status)
    return 'session_completed' if status == 'completed'

    status
  end

  def answered_session?(session)
    return true if session.answered_at.present?

    STATUS_PROGRESS.fetch(session.canonical_status, -1) >= STATUS_PROGRESS.fetch('in_progress')
  end

  def customer_answered_session?(session)
    return answered_session?(session) unless session.direction == 'outbound'
    return true if outbound_customer_answer_leg?(session)
    return false if outbound_operator_only_answered?(session)

    session.answered_at.present?
  end

  def outbound_customer_answer_leg?(session)
    Array.wrap(session.legs).any? do |leg|
      next false unless leg.is_a?(Hash)

      leg = leg.deep_stringify_keys
      leg['status'].to_s == 'in_progress' &&
        %w[answered call_status callee_answered customer_answered dial_status].include?(leg['event_type'].to_s) &&
        leg['leg'].to_s != 'operator'
    end
  end

  def outbound_operator_only_answered?(session)
    answered_legs = Array.wrap(session.legs).filter_map do |leg|
      next unless leg.is_a?(Hash)

      leg = leg.deep_stringify_keys
      leg if leg['status'].to_s == 'in_progress'
    end
    return false if answered_legs.blank?

    answered_legs.all? { |leg| leg['leg'].to_s == 'operator' }
  end

  def missing_duration_seconds(session, ended_at, target_status = nil)
    return session.duration_seconds if session.duration_seconds.present?
    return 0 if target_status.present? && target_status != 'completed' && !customer_answered_session?(session)

    started_at = session.answered_at || session.started_at || session.created_at
    return unless started_at.present? && ended_at.present?

    [ended_at.to_i - started_at.to_i, 0].max
  end

  def missing_sipuni_local_outbound_metadata(session, target_status)
    metadata = session.metadata.to_h.deep_dup
    metadata['sipuni_reconciliation'] = {
      'target_status' => target_status,
      'local_outbound_missing_provider_event' => true,
      'reconciled_at' => now.iso8601
    }
    metadata
  end

  def missing_sipuni_provider_metadata(session, target_status, previous_status)
    metadata = session.metadata.to_h.deep_dup
    metadata['sipuni_reconciliation'] = {
      'target_status' => target_status,
      'previous_status' => previous_status,
      'provider_terminal_missing' => true,
      'provider_call_sid' => session.provider_call_sid,
      'route_action' => route_action(session),
      'route_reason' => route_reason(session),
      'reconciled_at' => now.iso8601
    }.compact
    metadata
  end

  def missing_native_sip_metadata(session, target_status, previous_status)
    metadata = session.metadata.to_h.deep_dup
    metadata['native_sip_reconciliation'] = {
      'target_status' => target_status,
      'previous_status' => previous_status,
      'native_terminal_missing' => true,
      'provider' => session.provider,
      'route_action' => route_action(session),
      'route_reason' => route_reason(session),
      'reconciled_at' => now.iso8601
    }.compact
    metadata
  end

  def append_missing_sipuni_local_outbound_leg_snapshot(session, status)
    legs = Array(session.legs).map { |leg| leg.respond_to?(:to_h) ? leg.to_h : leg }
    legs << {
      'source' => SOURCE_SIPUNI_LOCAL_OUTBOUND_RECONCILIATION,
      'status' => status,
      'local_outbound_missing_provider_event' => true,
      'occurred_at' => now.iso8601
    }
    legs.last(20)
  end

  def append_missing_sipuni_provider_leg_snapshot(session, status, previous_status)
    legs = Array(session.legs).map { |leg| leg.respond_to?(:to_h) ? leg.to_h : leg }
    legs << {
      'source' => SOURCE_SIPUNI_PROVIDER_RECONCILIATION,
      'status' => status,
      'previous_status' => previous_status,
      'provider_terminal_missing' => true,
      'provider_call_sid' => session.provider_call_sid,
      'occurred_at' => now.iso8601
    }
    legs.last(20)
  end

  def append_missing_native_sip_leg_snapshot(session, status, previous_status)
    legs = Array(session.legs).map { |leg| leg.respond_to?(:to_h) ? leg.to_h : leg }
    legs << {
      'source' => SOURCE_NATIVE_SIP_RECONCILIATION,
      'status' => status,
      'previous_status' => previous_status,
      'native_terminal_missing' => true,
      'provider' => session.provider,
      'occurred_at' => now.iso8601
    }
    legs.last(20)
  end

  def missing_sipuni_provider_status(session)
    return 'completed' if session.canonical_status == 'in_progress' || session.answered_at.present?
    return 'no_answer' if session.direction == 'outbound'
    return 'no_answer' if route_action(session) == 'operator'

    'missed'
  end

  def missing_sipuni_provider_end_reason(session, target_status)
    return 'sipuni_provider_missing_completed_call' if target_status == 'completed'
    return 'sipuni_provider_missing_operator_no_answer' if target_status == 'no_answer' && route_action(session) == 'operator'
    return 'sipuni_provider_missing_outbound_no_answer' if target_status == 'no_answer'

    'sipuni_provider_terminal_missing'
  end

  def missing_native_sip_status(session)
    return 'completed' if session.canonical_status == 'in_progress' || session.answered_at.present?
    return 'no_answer' if session.direction == 'outbound'
    return 'no_answer' if route_action(session) == 'operator'

    'missed'
  end

  def missing_native_sip_end_reason(session, target_status)
    return 'native_sip_missing_completed_call' if target_status == 'completed'
    return 'native_sip_missing_operator_no_answer' if target_status == 'no_answer' && route_action(session) == 'operator'
    return 'native_sip_missing_outbound_no_answer' if target_status == 'no_answer'

    'native_sip_terminal_missing'
  end

  def generic_pre_answer_status(session)
    return 'no_answer' if session.direction == 'outbound'
    return 'no_answer' if route_action(session) == 'operator'

    'missed'
  end

  def generic_pre_answer_end_reason(session, target_status)
    return 'generic_pre_answer_stale_outbound_no_answer' if target_status == 'no_answer' && session.direction == 'outbound'
    return 'generic_pre_answer_stale_operator_no_answer' if target_status == 'no_answer'

    'generic_pre_answer_stale_inbound_missed'
  end

  def generic_pre_answer_metadata(session, target_status, previous_status)
    metadata = session.metadata.to_h.deep_dup
    metadata['generic_pre_answer_reconciliation'] = {
      'source' => SOURCE_GENERIC_PRE_ANSWER_RECONCILIATION,
      'target_status' => target_status,
      'previous_status' => previous_status,
      'pre_answer_stale' => true,
      'stale_after_seconds' => generic_pre_answer_stale_after.to_i,
      'stale_reference_at' => reconciliation_reference_time(session)&.iso8601,
      'provider' => session.provider,
      'provider_call_sid' => session.provider_call_sid,
      'route_action' => route_action(session),
      'route_reason' => route_reason(session),
      'reconciled_at' => now.iso8601
    }.compact
    metadata
  end

  def ai_pre_answer_metadata(session, target_status, previous_status)
    metadata = session.metadata.to_h.deep_dup
    metadata['ai_pre_answer_reconciliation'] = {
      'source' => SOURCE_AI_PRE_ANSWER_RECONCILIATION,
      'target_status' => target_status,
      'previous_status' => previous_status,
      'pre_answer_stale' => true,
      'stale_after_seconds' => ai_pre_answer_stale_after.to_i,
      'stale_reference_at' => reconciliation_reference_time(session)&.iso8601,
      'provider' => session.provider,
      'route_action' => route_action(session),
      'route_reason' => route_reason(session),
      'reconciled_at' => now.iso8601
    }.compact
    metadata
  end

  def append_generic_pre_answer_leg_snapshot(session, status, previous_status)
    legs = Array(session.legs).map { |leg| leg.respond_to?(:to_h) ? leg.to_h : leg }
    legs << {
      'source' => SOURCE_GENERIC_PRE_ANSWER_RECONCILIATION,
      'status' => status,
      'previous_status' => previous_status,
      'end_reason' => generic_pre_answer_end_reason(session, status),
      'pre_answer_stale' => true,
      'provider' => session.provider,
      'provider_call_sid' => session.provider_call_sid,
      'stale_reference_at' => reconciliation_reference_time(session)&.iso8601,
      'occurred_at' => now.iso8601
    }.compact
    legs.last(20)
  end

  def append_ai_pre_answer_leg_snapshot(session, status, previous_status)
    legs = Array(session.legs).map { |leg| leg.respond_to?(:to_h) ? leg.to_h : leg }
    legs << {
      'source' => SOURCE_AI_PRE_ANSWER_RECONCILIATION,
      'status' => status,
      'previous_status' => previous_status,
      'end_reason' => 'ai_runtime_terminal_missing',
      'pre_answer_stale' => true,
      'provider' => session.provider,
      'stale_reference_at' => reconciliation_reference_time(session)&.iso8601,
      'occurred_at' => now.iso8601
    }.compact
    legs.last(20)
  end

  def sipuni_local_outbound_session?(session)
    session.provider == 'sipuni' &&
      session.direction == 'outbound' &&
      session.provider_call_sid.blank? &&
      session.external_call_ref.to_s.start_with?('sipuni:local:')
  end

  def sipuni_provider_session?(session)
    session.provider == 'sipuni' && session.provider_call_sid.present?
  end

  def native_sip_session?(session)
    NATIVE_SIP_PROVIDERS.include?(session.provider) &&
      session.external_call_ref.to_s.start_with?("#{session.provider}:janus:")
  end

  def native_sip_local_outbound_session?(session)
    NATIVE_SIP_LOCAL_OUTBOUND_PROVIDERS.include?(session.provider) &&
      session.direction == 'outbound' &&
      session.provider_call_sid.blank? &&
      session.external_call_ref.to_s.start_with?("#{session.provider}:local:")
  end

  def generic_pre_answer_session?(session)
    !specific_reconciliation_session?(session)
  end

  def ai_pre_answer_session?(session)
    route_action(session) == 'ai'
  end

  def specific_reconciliation_session?(session)
    sipuni_local_outbound_session?(session) ||
      sipuni_provider_session?(session) ||
      native_sip_session?(session) ||
      native_sip_local_outbound_session?(session)
  end

  def generic_answer_evidence?(session)
    return true if session.answered_at.present?

    Array.wrap(session.legs).any? do |leg|
      next false unless leg.is_a?(Hash)

      leg = leg.deep_stringify_keys
      next false unless leg['status'].to_s == 'in_progress'

      ANSWER_EVIDENCE_EVENT_TYPES.include?(leg['event_type'].to_s) ||
        leg['answered_at'].present? ||
        leg['answered_by'].present?
    end
  end

  def route_action(session)
    route_metadata_value(session, 'route_action')
  end

  def route_reason(session)
    route_metadata_value(session, 'route_reason')
  end

  def route_metadata_value(session, key)
    metadata = session.metadata.to_h.deep_stringify_keys
    metadata[key].presence ||
      metadata.dig('metadata', key).presence ||
      metadata.dig('last_payload', 'metadata', key).presence
  end
end
