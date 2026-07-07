class Telephony::CallReconciliationService
  DEFAULT_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER = 60.seconds
  DEFAULT_SIPUNI_PROVIDER_RINGING_STALE_AFTER = 5.minutes
  DEFAULT_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER = 4.hours
  DEFAULT_NATIVE_SIP_PRE_ANSWER_STALE_AFTER = 5.minutes
  DEFAULT_NATIVE_SIP_IN_PROGRESS_STALE_AFTER = 4.hours
  DEFAULT_NATIVE_SIP_LOCAL_OUTBOUND_MISSING_AFTER = 60.seconds

  SOURCE_SIPUNI_LOCAL_OUTBOUND_RECONCILIATION = 'sipuni_local_outbound_reconciliation'.freeze
  SOURCE_SIPUNI_PROVIDER_RECONCILIATION = 'sipuni_provider_reconciliation'.freeze
  SOURCE_NATIVE_SIP_RECONCILIATION = 'native_sip_reconciliation'.freeze

  SIPUNI_PRE_ANSWER_STATUSES = %w[created ringing connecting].freeze
  NATIVE_SIP_PRE_ANSWER_STATUSES = %w[created ringing connecting].freeze
  NATIVE_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  NATIVE_SIP_LOCAL_OUTBOUND_PROVIDERS = %w[asterisk_analog binotel].freeze

  STATUS_PROGRESS = {
    'created' => 0,
    'ringing' => 1,
    'connecting' => 2,
    'in_progress' => 3
  }.freeze

  def initialize(account: nil, now: Time.current)
    @account = account
    @now = now
    @sipuni_local_outbound_missing_after = ENV.fetch(
      'TELEPHONY_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS',
      DEFAULT_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER.to_i
    ).to_i.seconds
    @sipuni_provider_ringing_stale_after = ENV.fetch(
      'TELEPHONY_SIPUNI_PROVIDER_RINGING_STALE_AFTER_SECONDS',
      DEFAULT_SIPUNI_PROVIDER_RINGING_STALE_AFTER.to_i
    ).to_i.seconds
    @sipuni_provider_in_progress_stale_after = ENV.fetch(
      'TELEPHONY_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER_SECONDS',
      DEFAULT_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER.to_i
    ).to_i.seconds
    @native_sip_pre_answer_stale_after = ENV.fetch(
      'TELEPHONY_NATIVE_SIP_PRE_ANSWER_STALE_AFTER_SECONDS',
      DEFAULT_NATIVE_SIP_PRE_ANSWER_STALE_AFTER.to_i
    ).to_i.seconds
    @native_sip_in_progress_stale_after = ENV.fetch(
      'TELEPHONY_NATIVE_SIP_IN_PROGRESS_STALE_AFTER_SECONDS',
      DEFAULT_NATIVE_SIP_IN_PROGRESS_STALE_AFTER.to_i
    ).to_i.seconds
    @native_sip_local_outbound_missing_after = ENV.fetch(
      'TELEPHONY_NATIVE_SIP_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS',
      DEFAULT_NATIVE_SIP_LOCAL_OUTBOUND_MISSING_AFTER.to_i
    ).to_i.seconds
  end

  def perform
    result = { checked: 0, updated: 0, missing: 0, errors: 0 }

    reconcile_missing_sipuni_local_outbound_sessions!(result)
    reconcile_missing_sipuni_provider_sessions!(result)
    reconcile_missing_native_sip_local_outbound_sessions!(result)
    reconcile_missing_native_sip_sessions!(result)

    result
  end

  private

  JANUS_NATIVE_SIP_REF_SQL = NATIVE_SIP_PROVIDERS.map { |provider| "external_call_ref LIKE '#{provider}:janus:%'" }.join(' OR ').freeze

  attr_reader :account, :now,
              :native_sip_in_progress_stale_after, :native_sip_local_outbound_missing_after, :native_sip_pre_answer_stale_after,
              :sipuni_local_outbound_missing_after, :sipuni_provider_in_progress_stale_after, :sipuni_provider_ringing_stale_after

  def sipuni_local_outbound_missing_scope
    scope = Telephony::CallSession.active
                                  .where(provider: 'sipuni', direction: 'outbound', provider_call_sid: nil)
                                  .where("external_call_ref LIKE 'sipuni:local:%'")
    scope = scope.where(account_id: account.id) if account.present?
    scope.where(
      'COALESCE(last_event_at, started_at, updated_at, created_at) <= ?',
      now - sipuni_local_outbound_missing_after
    )
  end

  def sipuni_provider_missing_scope
    scope = Telephony::CallSession.active
                                  .where(provider: 'sipuni')
                                  .where.not(provider_call_sid: nil)
    scope = scope.where(account_id: account.id) if account.present?

    reference_sql = 'COALESCE(last_event_at, started_at, updated_at, created_at)'
    scope.where(
      "(status IN (:pre_answer_statuses) AND #{reference_sql} <= :pre_answer_before) OR " \
      "(status = :in_progress_status AND #{reference_sql} <= :in_progress_before)",
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
      "(status IN (:pre_answer_statuses) AND #{reference_sql} <= :pre_answer_before) OR " \
      "(status = :in_progress_status AND #{reference_sql} <= :in_progress_before)",
      pre_answer_statuses: NATIVE_SIP_PRE_ANSWER_STATUSES,
      pre_answer_before: now - native_sip_pre_answer_stale_after,
      in_progress_status: 'in_progress',
      in_progress_before: now - native_sip_in_progress_stale_after
    )
  end

  def native_sip_local_outbound_missing_scope
    scope = Telephony::CallSession.active
                                  .where(provider: NATIVE_SIP_LOCAL_OUTBOUND_PROVIDERS, direction: 'outbound', provider_call_sid: nil)
                                  .where(status: NATIVE_SIP_PRE_ANSWER_STATUSES)
    scope = scope.where(account_id: account.id) if account.present?
    local_ref_sql = NATIVE_SIP_LOCAL_OUTBOUND_PROVIDERS.map { |provider| "external_call_ref LIKE '#{provider}:local:%'" }.join(' OR ')
    scope.where(local_ref_sql).where(
      'COALESCE(last_event_at, started_at, updated_at, created_at) <= ?',
      now - native_sip_local_outbound_missing_after
    )
  end

  def reconcile_missing_sipuni_local_outbound_sessions!(result)
    sipuni_local_outbound_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      result[:updated] += 1 if reconcile_missing_sipuni_local_outbound_session(session)
    end
  end

  def reconcile_missing_sipuni_provider_sessions!(result)
    sipuni_provider_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      result[:updated] += 1 if reconcile_missing_sipuni_provider_session(session)
    end
  end

  def reconcile_missing_native_sip_sessions!(result)
    native_sip_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      result[:updated] += 1 if reconcile_missing_native_sip_session(session)
    end
  end

  def reconcile_missing_native_sip_local_outbound_sessions!(result)
    native_sip_local_outbound_missing_scope.find_each do |session|
      result[:checked] += 1
      result[:missing] += 1
      result[:updated] += 1 if reconcile_missing_native_sip_local_outbound_session(session)
    end
  end

  def reconcile_missing_sipuni_local_outbound_session(session)
    return false if session.terminal?
    return false if session.provider_call_sid.present?

    ended_at = now
    target_status = 'failed'
    session.update!(
      status: target_status,
      ended_at: ended_at,
      ended_by: SOURCE_SIPUNI_LOCAL_OUTBOUND_RECONCILIATION,
      end_reason: 'sipuni_provider_event_missing',
      duration_seconds: missing_duration_seconds(session, ended_at, target_status),
      last_event_at: ended_at,
      metadata: missing_sipuni_local_outbound_metadata(session, target_status),
      legs: append_missing_sipuni_local_outbound_leg_snapshot(session, target_status)
    )
    sync_reconciled_session!(session, target_status, source: SOURCE_SIPUNI_LOCAL_OUTBOUND_RECONCILIATION)
    true
  end

  def reconcile_missing_sipuni_provider_session(session)
    return false if session.terminal?
    return false if session.provider_call_sid.blank?

    ended_at = now
    previous_status = session.canonical_status
    target_status = missing_sipuni_provider_status(session)
    session.update!(
      status: target_status,
      ended_at: ended_at,
      ended_by: SOURCE_SIPUNI_PROVIDER_RECONCILIATION,
      end_reason: missing_sipuni_provider_end_reason(session, target_status),
      duration_seconds: missing_duration_seconds(session, ended_at, target_status),
      last_event_at: ended_at,
      metadata: missing_sipuni_provider_metadata(session, target_status, previous_status),
      legs: append_missing_sipuni_provider_leg_snapshot(session, target_status, previous_status)
    )
    sync_reconciled_session!(session, target_status, source: SOURCE_SIPUNI_PROVIDER_RECONCILIATION)
    true
  end

  def reconcile_missing_native_sip_session(session)
    return false if session.terminal?

    ended_at = now
    previous_status = session.canonical_status
    target_status = missing_native_sip_status(session)
    session.update!(
      status: target_status,
      ended_at: ended_at,
      ended_by: SOURCE_NATIVE_SIP_RECONCILIATION,
      end_reason: missing_native_sip_end_reason(session, target_status),
      duration_seconds: missing_duration_seconds(session, ended_at, target_status),
      last_event_at: ended_at,
      metadata: missing_native_sip_metadata(session, target_status, previous_status),
      legs: append_missing_native_sip_leg_snapshot(session, target_status, previous_status)
    )
    sync_reconciled_session!(session, target_status, source: SOURCE_NATIVE_SIP_RECONCILIATION)
    true
  end

  def reconcile_missing_native_sip_local_outbound_session(session)
    return false if session.terminal?
    return false unless session.direction == 'outbound'

    ended_at = now
    previous_status = session.canonical_status
    target_status = 'no_answer'
    session.update!(
      status: target_status,
      ended_at: ended_at,
      ended_by: SOURCE_NATIVE_SIP_RECONCILIATION,
      end_reason: 'native_sip_missing_outbound_no_answer',
      duration_seconds: missing_duration_seconds(session, ended_at, target_status),
      last_event_at: ended_at,
      metadata: missing_native_sip_metadata(session, target_status, previous_status),
      legs: append_missing_native_sip_leg_snapshot(session, target_status, previous_status)
    )
    sync_reconciled_session!(session, target_status, source: SOURCE_NATIVE_SIP_RECONCILIATION)
    true
  end

  def sync_reconciled_session!(session, status, source: SOURCE_NATIVE_SIP_RECONCILIATION)
    return unless Telephony::CallSession::TERMINAL_STATUSES.include?(status)

    Telephony::EventsIngestionService.new(payload: reconciliation_event_payload(session, status, source: source)).perform
  rescue StandardError => e
    Rails.logger.warn(
      event: 'telephony_call_reconciliation_side_effect_failed',
      account_id: session.account_id,
      call_ref: session.external_call_ref,
      status: status,
      error_class: e.class.name,
      error_message: e.message
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
    return 'completed' if session.canonical_status == 'in_progress'
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
    return 'completed' if session.canonical_status == 'in_progress'
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
