require 'digest'
require 'json'

class Telephony::EventsIngestionService
  CALL_SESSION_CONFLICT_RETRIES = 2
  SIDE_EFFECT_CONFLICT_RETRIES = 2
  RETRYABLE_DATABASE_ERRORS = [
    ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout,
    ActiveRecord::RecordNotUnique,
    ActiveRecord::SerializationFailure
  ].freeze
  MISSED_INBOUND_TERMINAL_REASONS = %w[
    voice_stream_ended_before_operator_answer
  ].freeze
  UNANSWERED_TERMINAL_STATUSES = %w[
    missed
    no_answer
    rejected
  ].freeze
  OUTBOUND_CUSTOMER_ANSWER_EVENT_TYPES = %w[
    answered
    call_status
    callee_answered
    customer_answered
    dial_status
  ].freeze
  OUTBOUND_OPERATOR_CANCEL_REASONS = %w[
    operator_cancelled
    operator_canceled
  ].freeze
  RECONCILIATION_EVENT_SOURCES = %w[
    bridge_reconciliation
    sipuni_local_outbound_reconciliation
    sipuni_provider_reconciliation
  ].freeze

  EVENT_STATUS_MAP = {
    'created' => 'created',
    'queued' => 'created',
    'initiated' => 'created',
    'session_started' => 'ringing',
    'decision_received' => 'ringing',
    'operator_ringing' => 'ringing',
    'operator_answered' => 'in_progress',
    'operator_no_answer' => 'no_answer',
    'operator_timeout' => 'no_answer',
    'operator_failed' => 'failed',
    'caller_hangup' => 'cancelled',
    'call_started' => 'ringing',
    'stream_started' => 'in_progress',
    'media_stream_started' => 'in_progress',
    'media_stream_closed' => 'failed',
    'media_stream_not_established' => 'failed',
    'media_stream_framing_error' => 'failed',
    'media_writer_started' => nil,
    'first_audio_out_write' => nil,
    'app_received_call' => 'ringing',
    'app_answered' => 'in_progress',
    'ai_ringing' => 'ringing',
    'dial_status' => nil,
    'connecting' => 'connecting',
    'transfer_started' => 'in_progress',
    'transfer_requested' => nil,
    'transfer_result' => nil,
    'tool_started' => nil,
    'tool_progress' => nil,
    'tool_completed' => nil,
    'tool_failed' => nil,
    'tool_suppressed' => nil,
    'tool_async_completed' => nil,
    'tool_async_failed' => nil,
    'post_tool_model_stall' => nil,
    'business_faq_gate_fired' => nil,
    'business_faq_gate_result_injected' => nil,
    'ordinary_answer_model_stall' => nil,
    'incomplete_answer_model_stall' => nil,
    'ai_speaking' => nil,
    'caller_interrupted' => nil,
    'ringing' => 'ringing',
    'answer' => 'in_progress',
    'answered' => 'in_progress',
    'callee_answered' => 'in_progress',
    'customer_answered' => 'in_progress',
    'ai_answered' => 'in_progress',
    'transfer_answered' => 'in_progress',
    'in-progress' => 'in_progress',
    'in_progress' => 'in_progress',
    'inprogress' => 'in_progress',
    'session_completed' => 'completed',
    'transfer_completed' => 'completed',
    'hangup' => 'completed',
    'close' => 'completed',
    'call_ended' => 'completed',
    'provider_stream_closed' => nil,
    'provider_error' => 'failed',
    'realtime_interrupted' => nil,
    'recording_ready' => nil,
    'completed' => 'completed',
    'missed' => 'missed',
    'no-answer' => 'no_answer',
    'no_answer' => 'no_answer',
    'noanswer' => 'no_answer',
    'timeout' => 'no_answer',
    'busy' => 'busy',
    'cancelled' => 'cancelled',
    'canceled' => 'cancelled',
    'rejected' => 'rejected',
    'declined' => 'rejected',
    'session_failed' => 'failed',
    'transfer_failed' => 'failed',
    'unsupported_action' => 'failed',
    'error' => nil,
    'finalize' => nil,
    'failed' => 'failed'
  }.freeze

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    account = resolve_account!
    event = persist_event!(account)
    return event.call_session if event.processed? && event.call_session.present?

    process_event_with_retry!(account, event)
  rescue Telephony::Error => e
    event&.update(status: 'failed', error_message: e.message) if defined?(event) && event.present? && event.persisted?
    raise
  rescue StandardError => e
    unless defined?(event) && event.present? && event.persisted?
      raise
    end

    event.update(status: 'failed', error_message: e.message)
    Rails.logger.error(
      "TELEPHONY_VOICE_EVENT_SIDE_EFFECT_ERROR event_id=#{event.id} account_id=#{event.account_id} " \
      "event_type=#{event.event_type} call_ref=#{call_ref} error_class=#{e.class.name} message=#{e.message}"
    )
    event.call_session
  end

  private

  attr_reader :payload

  def process_event_with_retry!(account, event)
    retries = 0

    begin
      process_event!(account, event)
    rescue ActiveRecord::RecordNotUnique
      raise if retries >= CALL_SESSION_CONFLICT_RETRIES

      retries += 1
      event.reload
      return event.call_session if event.processed? && event.call_session.present?

      retry
    rescue *RETRYABLE_DATABASE_ERRORS
      raise if retries >= CALL_SESSION_CONFLICT_RETRIES

      retries += 1
      event.reload
      retry
    end
  end

  def process_event!(account, event)
    call_session = nil
    linked_runtime_call_sessions = []
    immutable_ai_finalized_late_event = false
    terminal_late_non_terminal_event = false
    terminal_late_terminal_event = false

    ActiveRecord::Base.transaction do
      event.lock!
      if event.processed? && event.call_session.present?
        call_session = event.call_session
        next
      end

      call_session = resolve_call_session!(account)
      call_session.with_lock do
        call_session.reload
        if immutable_ai_finalized_late_event?(call_session)
          immutable_ai_finalized_late_event = true
          event.update!(call_session: call_session, status: 'processed', processed_at: Time.current, error_message: nil)
          next
        end

        if terminal_late_non_terminal_event?(call_session)
          terminal_late_non_terminal_event = true
          event.update!(call_session: call_session, status: 'processed', processed_at: Time.current, error_message: nil)
          next
        end

        if terminal_late_terminal_event?(call_session)
          terminal_late_terminal_event = true
          event.update!(call_session: call_session, status: 'processed', processed_at: Time.current, error_message: nil)
          next
        end

        call_session = upsert_call_session!(call_session, account)
        linked_runtime_call_sessions = reconcile_linked_runtime_call_sessions!(account, call_session)
        event.update!(call_session: call_session, status: 'processed', processed_at: Time.current, error_message: nil)
      end
    end

    broadcast_realtime_call_status!(call_session) if call_session.present? && realtime_status_event?

    if call_session.present? && terminal_late_terminal_event
      reconcile_stale_terminal_voice_message!(call_session, account, event)
    elsif call_session.present? && !immutable_ai_finalized_late_event && !terminal_late_non_terminal_event
      run_side_effects!(call_session, account, event, linked_runtime_call_sessions: linked_runtime_call_sessions)
    end
    call_session
  end

  def immutable_ai_finalized_late_event?(call_session)
    return false if post_finalize_recording_event?

    call_session.metadata.to_h.dig('ai_voice', 'finalize').present?
  end

  def terminal_late_non_terminal_event?(call_session)
    return false if post_finalize_recording_event?
    return false unless call_session.terminal?

    status = resolved_status
    status.present? && !terminal_status?(status)
  end

  def terminal_late_terminal_event?(call_session)
    return false if post_finalize_recording_event?
    return false if terminal_recording_update_event?
    return false if webphone_release_event?
    return false if bridge_reconciliation_event?
    return false unless call_session.terminal?

    status = resolved_status
    return false unless terminal_status?(status)
    return false if terminal_supersedes_existing_terminal?(call_session)
    return false if terminal_duration_repair_needed?(call_session, status, resolved_occurred_at)

    true
  end

  def post_finalize_recording_event?
    resolved_event_type.in?(%w[recording_ready recording_incomplete]) || recording_error_event?
  end

  def terminal_recording_update_event?
    terminal_status?(resolved_status) &&
      recording_payload_value('recording_ref', 'recordingRef', 'recording_url', 'recordingUrl').present?
  end

  def webphone_release_event?
    event_key.to_s.start_with?('webphone:') ||
      metadata_value('webphone_action').to_s == 'operator_release'
  end

  def bridge_reconciliation_event?
    source = metadata_value('source').to_s
    RECONCILIATION_EVENT_SOURCES.any? { |candidate| event_key.to_s.start_with?("#{candidate}:") } ||
      RECONCILIATION_EVENT_SOURCES.include?(source)
  end

  def run_side_effects!(call_session, account, event, linked_runtime_call_sessions: [])
    retries = 0

    begin
      call_session.reload
      ensure_conversation!(call_session, account)
      call_session.reload
      apply_call_status!(call_session) unless suppress_fonoster_conversation_update?(call_session)
      sync_voice_message!(call_session)
      linked_runtime_call_sessions.each { |linked_call_session| sync_voice_message!(linked_call_session) }
      enqueue_external_recording_cache(call_session)
      enqueue_call_recording_transcription(call_session) if resolved_event_type == 'recording_ready'
    rescue *RETRYABLE_DATABASE_ERRORS => e
      retries += 1
      raise if retries > SIDE_EFFECT_CONFLICT_RETRIES

      Rails.logger.warn(
        "TELEPHONY_VOICE_EVENT_SIDE_EFFECT_RETRY event_id=#{event.id} account_id=#{event.account_id} " \
        "event_type=#{event.event_type} call_ref=#{call_session.external_call_ref} retry=#{retries} " \
        "error_class=#{e.class.name} message=#{e.message}"
      )
      sleep(0.05 * retries) unless Rails.env.test?
      retry
    rescue StandardError => e
      event.update(status: 'failed', error_message: e.message)
      Rails.logger.error(
        "TELEPHONY_VOICE_EVENT_SIDE_EFFECT_ERROR event_id=#{event.id} account_id=#{event.account_id} " \
        "event_type=#{event.event_type} call_ref=#{call_session.external_call_ref} error_class=#{e.class.name} message=#{e.message}"
      )
      call_session
    end
  end

  def realtime_status_event?
    resolved_status.present?
  end

  def broadcast_realtime_call_status!(call_session)
    tokens = realtime_call_status_pubsub_tokens(call_session)
    return if tokens.blank?

    event = {
      event: 'voice_call.status_changed',
      data: realtime_call_status_payload(call_session)
    }

    tokens.each { |token| ActionCable.server.broadcast(token, event) }
  rescue StandardError => e
    Rails.logger.warn(
      'TELEPHONY_REALTIME_CALL_STATUS_BROADCAST_FAILED ' \
      "call_ref=#{call_session&.external_call_ref} account_id=#{call_session&.account_id} error=#{e.class.name}: #{e.message}"
    )
  end

  def realtime_call_status_pubsub_tokens(call_session)
    user_ids = realtime_call_status_user_ids(call_session)
    tokens = []
    tokens += call_session.inbox.members.filter_map(&:pubsub_token) if call_session.inbox.present?
    tokens += call_session.account.users.where(id: user_ids).filter_map(&:pubsub_token) if user_ids.present?
    tokens.uniq
  end

  def realtime_call_status_user_ids(call_session)
    metadata = call_session.metadata.to_h.deep_stringify_keys
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
    candidates = route_metadata['operator_candidates'].is_a?(Array) ? route_metadata['operator_candidates'] : []

    [
      call_session.agent_binding&.user_id,
      metadata.dig('operator_claim', 'user_id'),
      route_metadata['operator_candidate_user_ids'],
      candidates.filter_map { |candidate| candidate['user_id'] }
    ].flatten.compact.map(&:to_i).uniq
  end

  def realtime_call_status_payload(call_session)
    metadata = call_session.metadata.to_h.deep_stringify_keys
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
    contact = call_session.contact

    {
      account_id: call_session.account_id,
      call_sid: call_session.external_call_ref,
      callSid: call_session.external_call_ref,
      call_ref: call_session.external_call_ref,
      provider: call_session.provider,
      status: call_session.canonical_status,
      call_direction: call_session.direction,
      direction: call_session.direction,
      conversation_id: call_session.conversation&.display_id,
      conversation_display_id: call_session.conversation&.display_id,
      conversation_db_id: call_session.conversation_id,
      inbox_id: call_session.inbox_id,
      number_ref: call_session.number_binding&.number_ref,
      logical_call_key: session_logical_call_key(call_session),
      logicalCallKey: session_logical_call_key(call_session),
      contact_id: call_session.contact_id,
      sender_id: call_session.contact_id,
      from_number: call_session.from_number,
      to_number: call_session.to_number,
      caller: realtime_call_status_caller_payload(contact, call_session),
      operator_claim: metadata['operator_claim'],
      operator_candidates: route_metadata['operator_candidates'],
      operator_internal_extension: route_metadata['operator_internal_extension']
    }.compact
  end

  def realtime_call_status_caller_payload(contact, call_session)
    return if contact.blank? && call_session.from_number.blank?

    {
      id: contact&.id,
      name: contact&.name,
      phone_number: contact&.phone_number || call_session.from_number
    }.compact
  end

  def reconcile_stale_terminal_voice_message!(call_session, account, event)
    call_session.reload
    return unless call_session.terminal?
    return unless stale_terminal_voice_message?(call_session)

    ensure_conversation!(call_session, account)
    call_session.reload
    sync_voice_message!(call_session)
  rescue StandardError => e
    event.update(status: 'failed', error_message: e.message)
    Rails.logger.error(
      "TELEPHONY_VOICE_EVENT_SIDE_EFFECT_ERROR event_id=#{event.id} account_id=#{event.account_id} " \
      "event_type=#{event.event_type} call_ref=#{call_session.external_call_ref} error_class=#{e.class.name} message=#{e.message}"
    )
    call_session
  end

  def stale_terminal_voice_message?(call_session)
    message = call_session.voice_message_for_current_call
    return false if message.blank?

    data = normalized_content_attributes(message).fetch('data', {})
    status = Telephony::CallSession.normalize_status(data['status']) || data['status'].to_s
    !terminal_status?(status)
  end

  def persist_event!(account)
    event = find_or_create_event!(account)
    return event if event.processed?

    updates = {}
    updates[:event_type] = resolved_event_type if event.event_type != resolved_event_type
    updates[:payload] = payload if event.payload != payload
    event.update!(updates) if updates.any?
    event
  end

  def resolve_account!
    account_id = payload_value('account_id', 'accountId') || metadata_value('chatwoot_account_id', 'account_id', 'accountId')
    return Account.find(account_id) if account_id.present?

    conversation = resolve_metadata_conversation
    return conversation.account if conversation.present?

    conversation = resolve_payload_conversation
    return conversation.account if conversation.present?

    inbox = resolve_metadata_inbox
    return inbox.account if inbox.present?

    contact = resolve_metadata_contact
    return contact.account if contact.present?

    binding = resolve_number_binding
    return binding.account if binding.present?

    call_session = uniquely_resolved_call_session
    return call_session.account if call_session.present?

    channel = Channel::Voice.find_by(phone_number: inbound_number)
    return channel.account if channel.present?

    raise Telephony::Error.new(code: 'ACCOUNT_NOT_FOUND', message: 'Unable to resolve account for telephony event', status: :not_found)
  end

  def resolve_call_session!(account)
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if call_ref.blank?

    if provider_call_sid.present?
      existing_by_provider_sid = account.telephony_call_sessions.find_by(provider_call_sid: provider_call_sid)
      return existing_by_provider_sid if existing_by_provider_sid.present?
    end

    account.telephony_call_sessions.find_by(external_call_ref: call_ref) ||
      account.telephony_call_sessions.create_or_find_by!(external_call_ref: call_ref)
  rescue ActiveRecord::RecordInvalid => e
    raise unless uniqueness_conflict?(e.record, :external_call_ref)

    account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def uniquely_resolved_call_session
    if provider_call_sid.present?
      sessions = Telephony::CallSession.where(provider_call_sid: provider_call_sid).limit(2).to_a
      return sessions.first if sessions.one?
    end

    return if call_ref.blank?

    sessions = Telephony::CallSession.where(external_call_ref: call_ref).limit(2).to_a
    sessions.one? ? sessions.first : nil
  end

  def upsert_call_session!(call_session, account)
    persist_call_session!(account, call_session) do |current_call_session|
      call_session_attributes(account, current_call_session)
    end
  end

  def reconcile_linked_runtime_call_sessions!(account, parent_call_session)
    return [] unless parent_call_session.terminal?

    refs = linked_runtime_call_refs - [parent_call_session.external_call_ref]
    return [] if refs.blank?

    reconciled_call_sessions = []
    account.telephony_call_sessions.where(external_call_ref: refs).where.not(id: parent_call_session.id).find_each do |child_call_session|
      child_call_session.with_lock do
        child_call_session.reload
        if child_call_session.terminal?
          reconciled_call_sessions << child_call_session
          next
        end

        child_call_session.assign_attributes(linked_runtime_child_attributes(parent_call_session, child_call_session))
        child_call_session.save!
        reconciled_call_sessions << child_call_session
      end
    end
    reconciled_call_sessions
  end

  def linked_runtime_child_attributes(parent_call_session, child_call_session)
    ended_at = parent_call_session.ended_at || resolved_ended_at || resolved_occurred_at || Time.current
    duration_seconds = child_call_session.duration_seconds || linked_runtime_child_duration(child_call_session, parent_call_session, ended_at)

    {
      status: parent_call_session.status,
      ended_at: child_call_session.ended_at || ended_at,
      ended_by: child_call_session.ended_by || parent_call_session.ended_by || resolved_ended_by,
      end_reason: child_call_session.end_reason || parent_call_session.end_reason || resolved_end_reason || parent_call_session.status,
      duration_seconds: duration_seconds,
      last_event_at: [child_call_session.last_event_at, parent_call_session.last_event_at, ended_at].compact.max,
      legs: linked_runtime_child_legs(parent_call_session, child_call_session),
      metadata: linked_runtime_child_metadata(parent_call_session, child_call_session)
    }
  end

  def linked_runtime_child_duration(child_call_session, parent_call_session, ended_at)
    return parent_call_session.duration_seconds if parent_call_session.duration_seconds.present?

    duration_start = child_call_session.answered_at ||
                     child_call_session.started_at ||
                     parent_call_session.answered_at ||
                     parent_call_session.started_at
    return if duration_start.blank? || ended_at.blank?

    [ended_at.to_i - duration_start.to_i, 0].max
  end

  def linked_runtime_child_legs(parent_call_session, child_call_session)
    legs = Array.wrap(child_call_session.legs).map { |leg| leg.is_a?(Hash) ? leg.deep_stringify_keys : leg }
    return legs if legs.any? { |leg| leg.is_a?(Hash) && leg['event_key'] == event_key }

    legs + [leg_snapshot(parent_call_session.status).merge(
      'leg' => 'ai',
      'bridge_call_ref' => parent_call_session.external_call_ref,
      'runtime_call_ref' => child_call_session.external_call_ref
    ).compact]
  end

  def linked_runtime_child_metadata(parent_call_session, child_call_session)
    metadata = (child_call_session.metadata || {}).deep_dup
    ai_voice = metadata['ai_voice'].is_a?(Hash) ? metadata['ai_voice'].deep_dup : {}
    ai_voice['linked_parent_terminal'] = {
      'bridge_call_ref' => parent_call_session.external_call_ref,
      'runtime_call_ref' => child_call_session.external_call_ref,
      'event_key' => event_key,
      'event_type' => resolved_event_type,
      'status' => parent_call_session.status,
      'ended_at' => (parent_call_session.ended_at || resolved_ended_at || resolved_occurred_at)&.iso8601,
      'end_reason' => parent_call_session.end_reason || resolved_end_reason,
      'stream_ref' => payload_value('stream_ref', 'streamRef') || nested_payload_value('stream_ref', 'streamRef'),
      'media_session_ref' => payload_value('media_session_ref', 'mediaSessionRef')
    }.compact
    metadata['ai_voice'] = ai_voice
    metadata.compact
  end

  def linked_runtime_call_refs
    [
      payload_value('runtime_call_ref', 'runtimeCallRef'),
      payload_value('child_call_ref', 'childCallRef'),
      payload_value('ai_runtime_call_ref', 'aiRuntimeCallRef')
    ].compact_blank.uniq
  end

  def call_session_attributes(account, call_session)
    conversation = resolve_existing_conversation(account, call_session)
    inbox = resolve_inbox(account, call_session)
    number_binding = resolve_number_binding(account, call_session) || inbox&.telephony_number_binding
    contact = resolve_contact(account, conversation, call_session)
    resolved_agent_binding = resolve_agent_binding(account)
    status = next_status_for(call_session)
    agent_binding = next_agent_binding(call_session, resolved_agent_binding, status)
    started_at = next_started_at(call_session, status)
    answered_at = next_answered_at(call_session, status)
    ended_at = next_ended_at(call_session, status)

    {
      account: account,
      conversation: conversation || call_session.conversation,
      contact: contact || call_session.contact,
      inbox: inbox || call_session.inbox,
      number_binding: number_binding || call_session.number_binding,
      agent_binding: agent_binding,
      provider: payload_value('provider') || call_session.provider || 'fonoster',
      provider_call_sid: payload_value('provider_call_sid', 'providerCallSid', 'provider_call_id',
                                       'providerCallId') || call_session.provider_call_sid,
      status: status,
      direction: next_direction(call_session),
      from_number: next_from_number(call_session),
      to_number: next_to_number(call_session),
      recording_ref: payload_value('recording_ref', 'recordingRef', 'recording_url', 'recordingUrl') ||
        nested_payload_value('recording_ref', 'recordingRef', 'recording_url', 'recordingUrl') ||
        call_session.recording_ref,
      transcript_ref: payload_value('transcript_ref', 'transcriptRef') || call_session.transcript_ref,
      summary: payload_value('summary') || nested_payload_value('summary') || call_session.summary,
      duration_seconds: next_duration_seconds(call_session, status, started_at, answered_at, ended_at),
      started_at: started_at,
      answered_at: answered_at,
      answered_by: next_answered_by(call_session, status),
      ended_at: ended_at,
      ended_by: next_ended_by(call_session, status),
      end_reason: next_end_reason(call_session, status),
      last_event_at: next_last_event_at(call_session),
      legs: next_legs(call_session, status),
      metadata: merged_metadata(call_session, conversation)
    }
  end

  def next_status_for(call_session)
    status = resolved_status
    return call_session.status if status.blank?
    return call_session.status if stale_event?(call_session)
    return call_session.status if call_session.terminal? && !terminal_status?(status)

    outbound_unanswered_terminal_status(call_session, status) || status
  end

  def next_agent_binding(call_session, resolved_agent_binding, status)
    return call_session.agent_binding if call_session.agent_binding.present? && operator_answer_event?(status)

    resolved_agent_binding || call_session.agent_binding
  end

  def operator_answer_event?(status)
    return false unless status == 'in_progress'

    resolved_event_type.to_s.in?(%w[operator_answered transfer_answered answered])
  end

  def next_started_at(call_session, status)
    return call_session.started_at if stale_event?(call_session)

    resolved_started_at || call_session.started_at || default_started_at(status)
  end

  def next_answered_at(call_session, status)
    return call_session.answered_at if stale_event?(call_session)

    resolved_answered_at || call_session.answered_at || (event_time if status == 'in_progress')
  end

  def next_answered_by(call_session, status)
    return call_session.answered_by if stale_event?(call_session)

    resolved_answered_by || call_session.answered_by || resolved_agent_actor(status)
  end

  def next_ended_at(call_session, status)
    return call_session.ended_at if stale_event?(call_session)
    return call_session.ended_at if post_finalize_recording_event? && call_session.ended_at.present?
    return event_time if terminal_supersedes_existing_terminal?(call_session)
    return resolved_ended_at || event_time if terminal_duration_repair_needed?(call_session, status, resolved_occurred_at)

    resolved_ended_at || call_session.ended_at || (event_time if terminal_status?(status))
  end

  def next_ended_by(call_session, status)
    return call_session.ended_by if stale_event?(call_session)
    return call_session.ended_by unless terminal_status?(status)

    resolved_ended_by || call_session.ended_by
  end

  def next_end_reason(call_session, status)
    return call_session.end_reason if stale_event?(call_session)
    return call_session.end_reason unless terminal_status?(status)

    resolved_end_reason || call_session.end_reason || status
  end

  def next_from_number(call_session)
    incoming_number = resolved_from_number
    if outbound_call_for?(call_session) && internal_outbound_number?(incoming_number, call_session)
      return call_session.from_number.presence || call_session.number_binding&.phone_number || incoming_number
    end

    incoming_number || call_session.from_number
  end

  def next_to_number(call_session)
    return resolved_outbound_customer_number(call_session) if outbound_call_for?(call_session)

    resolved_to_number || call_session.to_number
  end

  def next_direction(call_session)
    direction = resolved_direction
    return call_session.direction if preserve_existing_outbound_direction?(call_session, direction)

    direction || call_session.direction || 'inbound'
  end

  def outbound_call_for?(call_session)
    call_session.direction == 'outbound' || resolved_direction == 'outbound'
  end

  def resolved_outbound_customer_number(call_session)
    explicit_target = outbound_customer_target_number(call_session)
    return explicit_target if explicit_target.present?

    existing_target = call_session.to_number.presence
    incoming_target = resolved_to_number
    return existing_target if existing_target.present? && internal_outbound_number?(incoming_target, call_session)

    incoming_target.presence || existing_target
  end

  def outbound_customer_target_number(call_session)
    candidate = payload_value('outbound_target_number', 'outboundTargetNumber', 'customer_number', 'customerNumber',
                              'target_number', 'targetNumber', 'original_to', 'originalTo') ||
                nested_payload_value('outbound_target_number', 'outboundTargetNumber', 'customer_number', 'customerNumber',
                                     'target_number', 'targetNumber', 'original_to', 'originalTo') ||
                metadata_value('outbound_target_number', 'outboundTargetNumber', 'customer_number', 'customerNumber',
                               'target_number', 'targetNumber', 'original_to', 'originalTo') ||
                bridge_response_value(call_session, 'to', 'target_number', 'targetNumber', 'customer_number', 'customerNumber',
                                      'original_to', 'originalTo')
    normalize_phone_number(candidate) || candidate
  end

  def bridge_response_value(call_session, *keys)
    return if call_session.blank?

    bridge_response = call_session.metadata.to_h['bridge_response']
    return unless bridge_response.is_a?(Hash)

    candidates = [bridge_response]
    candidates << bridge_response['request'] if bridge_response['request'].is_a?(Hash)
    candidates << bridge_response['data'] if bridge_response['data'].is_a?(Hash)

    candidates.each do |source|
      source = source.deep_stringify_keys
      keys.each do |key|
        value = source[key.to_s]
        return value if value.present?
      end
    end

    nil
  end

  def internal_outbound_number?(value, call_session)
    return false if value.blank?

    normalized_candidate = normalized_phone(value)
    return true if normalized_candidate.blank? || normalized_candidate.length <= 4
    return true if normalized_candidate == normalized_phone(inbound_number)
    return true if normalized_candidate == normalized_phone(call_session.number_binding&.phone_number)
    return true if normalized_candidate == normalized_phone(call_session.inbox&.channel&.try(:phone_number))

    false
  end

  def outbound_unanswered_terminal_status(call_session, status)
    return unless status == 'completed'
    return unless outbound_call_for?(call_session)
    return if webphone_operator_completed_release_event?
    return if outbound_customer_answered?(call_session)

    outbound_operator_cancel_event? ? 'cancelled' : 'no_answer'
  end

  def webphone_operator_completed_release_event?
    webphone_release_event? &&
      metadata_value('webphone_action').to_s == 'operator_release' &&
      resolved_end_reason.to_s == 'operator_hangup'
  end

  def outbound_customer_answered?(call_session)
    outbound_customer_answer_event? ||
      outbound_customer_answer_payload? ||
      (call_session.answered_at.present? && !outbound_operator_only_answered?(call_session)) ||
      Array.wrap(call_session.legs).any? { |leg| outbound_customer_answer_leg?(leg) }
  end

  def outbound_operator_only_answered?(call_session)
    answered_legs = Array.wrap(call_session.legs).filter_map do |leg|
      next unless leg.is_a?(Hash)

      leg = leg.deep_stringify_keys
      leg if leg['status'].to_s == 'in_progress'
    end
    return false if answered_legs.blank?

    answered_legs.all? { |leg| leg['leg'].to_s == 'operator' }
  end

  def outbound_customer_answer_event?
    return false unless resolved_status == 'in_progress'
    return false unless OUTBOUND_CUSTOMER_ANSWER_EVENT_TYPES.include?(resolved_event_type.to_s)
    return false if operator_leg_event?

    true
  end

  def outbound_customer_answer_payload?
    return false if operator_leg_event?

    truthy_payload_value?('calleeLegAnswered', 'callee_leg_answered', 'targetLegAnswered', 'target_leg_answered') ||
      (terminal_status?(resolved_status) && resolved_answered_at.present?)
  end

  def outbound_customer_answer_leg?(leg)
    return false unless leg.is_a?(Hash)

    leg = leg.deep_stringify_keys
    return false unless leg['status'].to_s == 'in_progress'
    return false unless OUTBOUND_CUSTOMER_ANSWER_EVENT_TYPES.include?(leg['event_type'].to_s)
    return false if leg['leg'].to_s == 'operator'

    true
  end

  def outbound_operator_cancel_event?
    reason = resolved_end_reason.to_s.strip.downcase
    OUTBOUND_OPERATOR_CANCEL_REASONS.include?(reason)
  end

  def preserve_existing_outbound_direction?(call_session, direction)
    return false unless call_session.direction == 'outbound'
    return false unless direction == 'inbound'

    outbound_origin_metadata?(call_session) && operator_leg_event?
  end

  def outbound_origin_metadata?(call_session)
    metadata = call_session.metadata.to_h.deep_stringify_keys
    return true if metadata['bridge_response'].present? || metadata['fonoster_call_ref'].present?

    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'].deep_stringify_keys : {}
    outbound_values = %w[outbound to_pstn outbound_api outbound-dial outbound_api_call]

    outbound_values.include?(route_metadata['direction'].to_s.strip.downcase) ||
      outbound_values.include?(route_metadata['call_direction'].to_s.strip.downcase) ||
      outbound_values.include?(route_metadata['callDirection'].to_s.strip.downcase)
  end

  def operator_leg_event?
    explicit_leg = payload_value('leg', 'legType', 'leg_type').to_s
    return explicit_leg == 'operator' if explicit_leg.present?

    payload_value('routingMode', 'routing_mode', 'mode').to_s == 'operator'
  end

  def next_duration_seconds(call_session, status, started_at, answered_at, ended_at)
    return call_session.duration_seconds if stale_event?(call_session)

    if post_finalize_recording_event? && call_session.duration_seconds.present?
      current_duration = call_session.duration_seconds.to_i
      return current_duration unless recomputable_completed_duration?(status, current_duration, answered_at, ended_at)
    end

    reconciliation_duration = reconciliation_terminal_duration_seconds(status, answered_at, ended_at)
    return reconciliation_duration if reconciliation_duration.present?

    return [ended_at.to_i - started_at.to_i, 0].max if unanswered_terminal_status?(status) && started_at.present? && ended_at.present?

    explicit_duration = resolved_duration
    if explicit_duration.present?
      explicit_duration = explicit_duration.to_i
      return explicit_duration unless recomputable_completed_duration?(status, explicit_duration, answered_at, ended_at)
    end

    if call_session.duration_seconds.present?
      current_duration = call_session.duration_seconds.to_i
      repaired_duration = repaired_completed_duration(call_session, status, answered_at, ended_at, current_duration)
      return repaired_duration if repaired_duration.present?

      return current_duration unless recomputable_completed_duration?(status, current_duration, answered_at, ended_at)
    end

    return unless terminal_status?(status)

    duration_start = answered_at || started_at
    return if duration_start.blank? || ended_at.blank?

    [ended_at.to_i - duration_start.to_i, 0].max
  end

  def reconciliation_terminal_duration_seconds(status, answered_at, ended_at)
    return unless bridge_reconciliation_event?
    return unless terminal_status?(status)

    explicit_duration = resolved_duration
    return explicit_duration if explicit_duration.present?
    return completed_duration_seconds(answered_at, ended_at) if status == 'completed'

    0
  end

  def recomputable_completed_duration?(status, duration, answered_at, ended_at)
    status == 'completed' && duration.zero? && answered_at.present? && ended_at.present? && ended_at > answered_at
  end

  def repaired_completed_duration(call_session, status, answered_at, ended_at, current_duration = call_session.duration_seconds)
    if repairable_terminal_upgrade?(call_session, status)
      repaired_duration = completed_duration_seconds(answered_at, ended_at)
      return repaired_duration if repaired_duration.present?
    end

    repaired_duration = completed_duration_seconds(answered_at, ended_at)
    return repaired_duration if completed_terminal_duration_mismatch?(call_session, status, repaired_duration, current_duration)

    return unless longer_completed_terminal_duration_repair_needed?(call_session, status, answered_at, ended_at, current_duration)

    repaired_duration
  end

  def completed_terminal_duration_mismatch?(call_session, status, repaired_duration, current_duration = call_session.duration_seconds)
    return false unless status == 'completed'
    return false unless call_session.terminal?
    return false unless resolved_event_type.to_s == 'session_completed'
    return false unless answered_terminal_evidence?(call_session)
    return false if incoming_terminal_priority < existing_terminal_priority(call_session)
    return false if repaired_duration.blank? || repaired_duration <= 0 || current_duration.blank?

    repaired_duration != current_duration.to_i
  end

  def unanswered_terminal_status?(status)
    status.to_s.in?(UNANSWERED_TERMINAL_STATUSES)
  end

  def next_legs(call_session, status)
    legs = Array.wrap(call_session.legs).map { |leg| leg.is_a?(Hash) ? leg.deep_stringify_keys : leg }
    return legs if legs.any? { |leg| leg.is_a?(Hash) && leg['event_key'] == event_key }

    legs + [leg_snapshot(status, call_session: call_session)]
  end

  def next_last_event_at(call_session)
    occurred_at = resolved_occurred_at
    return call_session.last_event_at if stale_event?(call_session)
    return call_session.last_event_at if post_finalize_recording_event? && call_session.terminal? && call_session.last_event_at.present?
    return [call_session.last_event_at, occurred_at].compact.max if occurred_at.present?

    Time.current
  end

  def stale_event?(call_session)
    occurred_at = resolved_occurred_at
    return false if fresh_terminal_event?(call_session, occurred_at)

    occurred_at.present? && call_session.last_event_at.present? && occurred_at < call_session.last_event_at
  end

  def fresh_terminal_event?(call_session, occurred_at)
    terminal_supersedes_existing_terminal?(call_session) ||
      (occurred_at.present? && terminal_status?(resolved_status) && !call_session.terminal?) ||
      repairable_stale_terminal_event?(call_session, occurred_at)
  end

  def terminal_supersedes_existing_terminal?(call_session)
    return false unless terminal_supersede_candidate?(call_session)

    incoming_terminal_time < call_session.ended_at &&
      incoming_terminal_priority >= existing_terminal_priority(call_session)
  end

  def terminal_supersede_candidate?(call_session)
    call_session.terminal? &&
      terminal_status?(resolved_status) &&
      !post_finalize_recording_event? &&
      incoming_terminal_time.present? &&
      call_session.ended_at.present?
  end

  def incoming_terminal_time
    resolved_ended_at || resolved_occurred_at
  end

  def incoming_terminal_priority
    terminal_priority(resolved_ended_by, resolved_end_reason)
  end

  def existing_terminal_priority(call_session)
    terminal_priority(call_session.ended_by, call_session.end_reason)
  end

  def terminal_priority(ended_by, end_reason)
    value = [ended_by, end_reason].compact.join(' ').downcase
    return 3 if value.include?('caller') || value.include?('remote')
    return 2 if value.include?('operator') || value.include?('user:')
    return 1 if value.present?

    0
  end

  def repairable_stale_terminal_event?(call_session, occurred_at)
    return false if occurred_at.blank? || call_session.last_event_at.blank?
    return false unless occurred_at < call_session.last_event_at
    return false unless call_session.terminal?

    status = resolved_status
    return false unless terminal_status?(status)
    return false unless status == call_session.status || repairable_terminal_upgrade?(call_session, status)

    terminal_duration_repair_needed?(call_session, status, occurred_at)
  end

  def repairable_terminal_upgrade?(call_session, status)
    status == 'completed' && call_session.status.in?(%w[no_answer missed cancelled failed]) && answered_terminal_evidence?(call_session)
  end

  def terminal_duration_repair_needed?(call_session, status, occurred_at)
    return false unless status == 'completed'

    answered_at = resolved_answered_at || call_session.answered_at
    ended_at = resolved_ended_at || occurred_at || call_session.ended_at || event_time
    return true if repairable_terminal_upgrade?(call_session, status) && answered_at.present? && ended_at.present?

    recomputable_completed_duration?(status, call_session.duration_seconds.to_i, answered_at, ended_at) ||
      completed_terminal_duration_mismatch?(call_session, status, completed_duration_seconds(answered_at, ended_at)) ||
      longer_completed_terminal_duration_repair_needed?(call_session, status, answered_at, ended_at)
  end

  def longer_completed_terminal_duration_repair_needed?(call_session, status, answered_at, ended_at, current_duration = call_session.duration_seconds)
    return false unless status == 'completed'
    return false unless call_session.terminal?
    return false unless resolved_event_type.to_s == 'session_completed'
    return false if ended_at.blank? || answered_at.blank?
    return false if call_session.ended_at.present? && ended_at <= call_session.ended_at
    return false if incoming_terminal_priority < existing_terminal_priority(call_session)

    repaired_duration = completed_duration_seconds(answered_at, ended_at)
    return false if repaired_duration.blank? || repaired_duration <= 0

    current_duration.blank? || repaired_duration > current_duration.to_i
  end

  def completed_duration_seconds(answered_at, ended_at)
    return if answered_at.blank? || ended_at.blank? || ended_at <= answered_at

    [ended_at.to_i - answered_at.to_i, 0].max
  end

  def answered_terminal_evidence?(call_session)
    return true if resolved_answered_at.present? || call_session.answered_at.present?

    call_session.legs.to_a.any? do |leg|
      leg.is_a?(Hash) && leg['status'].to_s == 'in_progress'
    end
  end

  def terminal_status?(status)
    Telephony::CallSession::TERMINAL_STATUSES.include?(status)
  end

  def ensure_conversation!(call_session, account)
    return if call_session.conversation.present?

    inbox = call_session.inbox || resolve_inbox(account)
    if inbox.blank?
      raise Telephony::Error.new(code: 'VOICE_INBOX_NOT_FOUND', message: "Unable to resolve voice inbox for #{call_session.direction} call",
                                 status: :not_found)
    end

    conversation = if call_session.direction == 'inbound'
                     ensure_inbound_conversation!(account: account, inbox: inbox)
                   else
                     ensure_outbound_conversation!(account: account, inbox: inbox, call_session: call_session)
                   end

    call_session.update!(
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      number_binding: inbox.telephony_number_binding || call_session.number_binding
    )
  end

  def ensure_inbound_conversation!(account:, inbox:)
    Voice::InboundCallBuilder.perform!(
      account: account,
      inbox: inbox,
      from_number: normalized_caller_number || caller_number,
      call_sid: call_ref
    )
  end

  def ensure_outbound_conversation!(account:, inbox:, call_session:)
    contact_number = call_session.to_number.presence || resolved_to_number
    if contact_number.blank?
      raise Telephony::Error.new(code: 'CONTACT_PHONE_NOT_FOUND', message: 'Unable to resolve contact phone number for outbound call',
                                 status: :unprocessable_content)
    end

    contact = ensure_call_contact!(account, contact_number)
    contact_inbox = ensure_call_contact_inbox!(contact, inbox, contact_number)
    conversation = account.conversations.find_by(identifier: call_ref) ||
                   reusable_fonoster_conversation(account: account, inbox: inbox, contact: contact, call_session: call_session) ||
                   create_outbound_conversation!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                                 call_session: call_session)

    update_outbound_conversation!(conversation, call_session)
    conversation
  end

  def create_outbound_conversation!(account:, inbox:, contact:, contact_inbox:, call_session:)
    attrs = {
      contact_inbox_id: contact_inbox.id,
      inbox_id: inbox.id,
      contact_id: contact.id,
      status: :open
    }
    attrs[:identifier] = call_ref unless fonoster_call_session?(call_session)

    account.conversations.create!(attrs)
  end

  def ensure_call_contact!(account, phone_number)
    account.contacts.find_or_create_by!(phone_number: phone_number) do |record|
      record.name = phone_number if record.name.blank?
    end
  end

  def ensure_call_contact_inbox!(contact, inbox, source_id)
    ContactInbox.find_or_create_by!(contact_id: contact.id, inbox_id: inbox.id) do |record|
      record.source_id = source_id
    end
  end

  def update_outbound_conversation!(conversation, call_session)
    timestamp = (call_session.started_at || call_session.created_at || Time.current).to_i
    attrs = (conversation.additional_attributes || {}).deep_dup
    reset_reused_fonoster_call_state!(attrs, call_session)
    attrs['call_direction'] = 'outbound'
    attrs['call_status'] = call_session.status
    attrs['conference_sid'] ||= Voice::Conference::Name.for(conversation)
    attrs['telephony_provider'] = call_session.provider
    attrs['from_number'] = call_session.from_number if call_session.from_number.present?
    attrs['to_number'] = call_session.to_number if call_session.to_number.present?
    attrs['fonoster_call_ref'] = call_session.external_call_ref if fonoster_call_session?(call_session)
    attrs['meta'] = attrs['meta'].is_a?(Hash) ? attrs['meta'] : {}
    attrs['meta']['initiated_at'] = timestamp

    update_attrs = { additional_attributes: attrs, last_activity_at: Time.current }
    update_attrs[:identifier] = call_session.external_call_ref unless fonoster_call_session?(call_session)
    update_attrs[:status] = :open if fonoster_call_session?(call_session)

    conversation.update!(update_attrs)
  end

  def apply_call_status!(call_session)
    conversation = call_session.conversation
    return if conversation.blank?

    prepare_reused_fonoster_conversation_for_call!(conversation, call_session)

    if resolved_status.present?
      timestamp = call_status_timestamp(call_session)
      Voice::CallStatus::Manager.new(
        conversation: conversation,
        call_sid: call_session.external_call_ref
      ).process_status_update(
        call_session.status,
        duration: call_session.duration_seconds,
        timestamp: timestamp
      )
    end

    conversation.reload if resolved_status.present?
    attrs = (conversation.additional_attributes || {}).deep_dup
    reset_reused_fonoster_call_state!(attrs, call_session)
    attrs['telephony_provider'] = call_session.provider
    attrs['call_direction'] = call_session.direction if fonoster_call_session?(call_session)
    attrs['from_number'] = call_session.from_number if call_session.from_number.present?
    attrs['to_number'] = call_session.to_number if call_session.to_number.present?
    attrs['fonoster_call_ref'] = call_session.external_call_ref if fonoster_call_session?(call_session)
    recording_metadata = presentation_recording_metadata(call_session)
    attrs['recording_ref'] = recording_metadata['recording_ref'] if recording_metadata['recording_ref'].present?
    attrs['recording'] = recording_metadata if recording_metadata.present?
    attrs['transcript_ref'] = call_session.transcript_ref if call_session.transcript_ref.present?
    attrs['summary'] = call_session.summary if call_session.summary.present?
    update_attrs = { additional_attributes: attrs, last_activity_at: Time.current }
    update_attrs[:status] = :open if fonoster_call_session?(call_session)
    conversation.update!(update_attrs)
  end

  def prepare_reused_fonoster_conversation_for_call!(conversation, call_session)
    return unless fonoster_call_session?(call_session)

    attrs = (conversation.additional_attributes || {}).deep_dup
    previous_call_ref = attrs['fonoster_call_ref']
    return if previous_call_ref.blank? || previous_call_ref == call_session.external_call_ref

    reset_reused_fonoster_call_state!(attrs, call_session)
    attrs['telephony_provider'] = call_session.provider
    attrs['call_direction'] = call_session.direction
    attrs['from_number'] = call_session.from_number if call_session.from_number.present?
    attrs['to_number'] = call_session.to_number if call_session.to_number.present?
    attrs['fonoster_call_ref'] = call_session.external_call_ref
    conversation.update!(additional_attributes: attrs)
    conversation.reload
  end

  def superseded_fonoster_conversation_call?(call_session)
    return false unless fonoster_call_session?(call_session)

    conversation = call_session.conversation
    return false if conversation.blank?

    attrs = (conversation.additional_attributes || {}).deep_stringify_keys
    current_call_ref = attrs['fonoster_call_ref'].presence
    return false if current_call_ref.blank? || current_call_ref == call_session.external_call_ref

    current_call_started_at = fonoster_conversation_call_started_at(conversation, current_call_ref, attrs)
    call_session_started_at = call_session.started_at || call_session.created_at
    return false if current_call_started_at.blank? || call_session_started_at.blank?

    current_call_started_at > call_session_started_at
  end

  def suppress_fonoster_conversation_update?(call_session)
    superseded_fonoster_conversation_call?(call_session) ||
      unanswered_linked_fonoster_branch?(call_session)
  end

  def fonoster_conversation_call_started_at(conversation, call_ref, attrs)
    current_session = conversation.account.telephony_call_sessions.find_by(external_call_ref: call_ref)
    current_session&.started_at || current_session&.created_at || fonoster_conversation_attrs_started_at(attrs)
  end

  def fonoster_conversation_attrs_started_at(attrs)
    meta = attrs['meta'].is_a?(Hash) ? attrs['meta'] : {}
    timestamp = meta['initiated_at'] || attrs['call_started_at']
    return if timestamp.blank?

    timestamp.to_s.match?(/\A\d+\z/) ? Time.zone.at(timestamp.to_i) : parse_time(timestamp)
  end

  def call_status_timestamp(call_session)
    return (call_session.answered_at || call_session.started_at)&.to_i if call_session.status == 'in_progress'
    return (call_session.ended_at || call_session.started_at)&.to_i if terminal_status?(call_session.status)

    call_session.started_at&.to_i
  end

  def reset_reused_fonoster_call_state!(attrs, call_session)
    return unless fonoster_call_session?(call_session)

    previous_call_ref = attrs['fonoster_call_ref']
    return if previous_call_ref.blank? || previous_call_ref == call_session.external_call_ref

    %w[
      agent_id
      call_started_at
      call_ended_at
      call_duration
      recording_ref
      recording
      transcript_ref
      summary
      from_number
      to_number
    ].each { |key| attrs.delete(key) }
  end

  def sync_voice_message!(call_session)
    message = voice_message_for(call_session)
    return if message.blank? && (
      superseded_fonoster_conversation_call?(call_session) ||
      suppress_linked_unanswered_fonoster_branch!(call_session)
    )

    message ||= build_voice_message!(call_session)
    return unless message

    data = normalized_content_attributes(message)
    data['data'] ||= {}
    voice_meta = voice_message_meta(call_session)
    if voice_meta.present?
      existing_meta = data['data']['meta'].is_a?(Hash) ? data['data']['meta'] : {}
      data['data']['meta'] = existing_meta.merge(voice_meta)
    end
    if (accepted_by = accepted_by_from_operator_claim(call_session, voice_meta['operator_claim'])).present?
      data['data']['accepted_by'] = accepted_by
    end
    data['data']['status'] = call_session.canonical_status
    if (logical_key = logical_call_key(call_session)).present?
      data['data']['logical_call_key'] = logical_key
      data['data']['logicalCallKey'] = logical_key
      data['data']['call_group_key'] = logical_key
      data['data']['callGroupKey'] = logical_key
    end
    if message.source_id.blank? || message.source_id == call_session.voice_call_source_id
      data['data']['call_sid'] = call_session.external_call_ref
      data['data']['call_direction'] ||= call_session.direction
      data['data']['from_number'] ||= call_session.from_number
      data['data']['to_number'] ||= call_session.to_number
    end
    if (communication_thread_id = communication_thread_id_for(call_session)).present?
      data['data']['communication_thread_id'] = communication_thread_id
      data['data']['communicationThreadId'] = communication_thread_id
    end
    data['data']['provider'] ||= call_session.provider
    data['data']['inbox_id'] ||= call_session.inbox_id
    existing_ai_voice = data['data']['ai_voice'].is_a?(Hash) ? data['data']['ai_voice'] : {}
    data['data']['ai_voice'] = existing_ai_voice.merge(voice_ai_message_state(call_session))
    tools = voice_ai_tool_events(call_session)
    data['data']['tools'] = tools if tools.present?
    recording_metadata = presentation_recording_metadata(call_session)
    if recording_metadata.present?
      data['data']['recording_ref'] = recording_metadata['recording_ref'] if recording_metadata['recording_ref'].present?
      data['data']['recording'] = recording_metadata
      data['data']['recording_url'] = recording_url(call_session)
    end
    data['data']['transcript_ref'] = call_session.transcript_ref if call_session.transcript_ref.present?
    transcript = payload_value('transcript')
    data['data']['transcript'] = transcript if transcript.present?
    data['data']['summary'] = call_session.summary if call_session.summary.present?
    data['data']['duration'] = call_session.duration_seconds if call_session.duration_seconds.present?
    message.source_id ||= call_session.voice_call_source_id
    message.update!(content_attributes: data)
    remove_fonoster_group_duplicate_messages!(call_session, message)
    mark_linked_runtime_duplicate_message!(call_session, message)
  end

  def mark_linked_runtime_duplicate_message!(call_session, canonical_message)
    duplicate = call_session.exact_voice_message
    return if duplicate.blank? || canonical_message.blank? || duplicate.id == canonical_message.id

    duplicate_attrs = normalized_content_attributes(duplicate)
    duplicate_attrs['data'] ||= {}
    canonical_data = normalized_content_attributes(canonical_message).fetch('data', {})
    duplicate_attrs['data']['status'] = canonical_data['status'] if canonical_data['status'].present?
    duplicate_attrs['data']['ai_voice'] = canonical_data['ai_voice'] if canonical_data['ai_voice'].is_a?(Hash)
    duplicate_attrs['data']['hidden'] = true
    duplicate_attrs['data']['duplicate_of'] = canonical_message.source_id
    duplicate_attrs['data']['ai_voice'] = (duplicate_attrs['data']['ai_voice'].is_a?(Hash) ? duplicate_attrs['data']['ai_voice'] : {}).merge(
      'duplicate_of' => canonical_message.source_id,
      'canonical_call_sid' => canonical_data['call_sid']
    ).compact
    duplicate.update!(content_attributes: duplicate_attrs)
  end

  def normalized_content_attributes(message)
    raw_attributes = message&.content_attributes
    attributes = if raw_attributes.is_a?(String)
                   JSON.parse(raw_attributes)
                 elsif raw_attributes.respond_to?(:to_h)
                   raw_attributes.to_h
                 else
                   {}
                 end

    return {} unless attributes.is_a?(Hash)

    attributes.deep_dup.deep_stringify_keys
  rescue JSON::ParserError
    {}
  end

  def enqueue_call_recording_transcription(call_session)
    return unless call_session.account.feature_enabled?('captain_integration')
    return unless call_session.account.captain_audio_transcription_enabled?
    return if call_recording_metadata(call_session)['storage_key'].blank?
    return if outbound_without_customer_answer?(call_session)

    enqueue_job = false
    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      recording = metadata['recording'] ||= {}
      transcription = recording['transcription'] ||= {}
      next if %w[queued completed].include?(transcription['status'])

      transcription['status'] = 'queued'
      transcription['queued_at'] = Time.current.iso8601
      call_session.update!(metadata: metadata)
      enqueue_job = true
    end

    return unless enqueue_job

    Telephony::CallRecordingTranscriptionJob.perform_later(call_session.id)
  end

  def voice_message_for(call_session)
    return if call_session.conversation.blank?
    return exact_voice_message_for(call_session) if superseded_fonoster_conversation_call?(call_session)
    return if unanswered_linked_fonoster_branch?(call_session)

    call_session.voice_message_for_current_call
  end

  def unanswered_linked_fonoster_branch?(call_session)
    return false unless fonoster_call_session?(call_session)
    return false unless call_session.direction == 'inbound'
    return false unless unanswered_terminal_status?(call_session.status)

    linked_parent_voice_message_for(call_session).present? ||
      linked_answered_fonoster_call_session_for(call_session).present? ||
      linked_logical_group_voice_message_for(call_session).present? ||
      linked_unanswered_fonoster_voice_message_for(call_session).present? ||
      linked_recent_context_voice_message_for(call_session).present?
  end

  def suppress_linked_unanswered_fonoster_branch!(call_session)
    return false unless unanswered_linked_fonoster_branch?(call_session)

    exact_voice_message_for(call_session)&.destroy!
    true
  end

  def linked_answered_fonoster_call_session_for(call_session)
    return if call_session.conversation.blank?

    event_start = call_session.started_at || call_session.created_at
    scope = call_session.conversation.account.telephony_call_sessions
                        .where(conversation_id: call_session.conversation_id, provider: 'fonoster', direction: 'inbound')
                        .where.not(id: call_session.id)
    scope = scope.where(created_at: event_start - 2.minutes..event_start + 2.minutes) if event_start.present?

    current_key = session_logical_call_key(call_session).presence || logical_call_key(call_session)
    scope.order(created_at: :desc, id: :desc).detect do |candidate|
      next false if unanswered_terminal_status?(candidate.status)
      next false unless candidate.answered_at.present? || %w[in_progress completed].include?(candidate.status)

      linked_fonoster_call_session_matches?(candidate, call_session, current_key, event_start)
    end
  end

  def linked_fonoster_call_session_matches?(candidate, call_session, current_key, event_start)
    candidate_key = session_logical_call_key(candidate)
    return true if current_key.present? && candidate_key.to_s == current_key.to_s

    candidate_start = candidate.started_at || candidate.created_at
    return false if event_start.present? && candidate_start.present? &&
                    !candidate_start.between?(event_start - 90.seconds, event_start + 90.seconds)

    same_phone_value?(candidate.from_number, call_session.from_number) &&
      same_phone_value?(candidate.to_number, call_session.to_number)
  end

  def linked_parent_voice_message_for(call_session)
    parent_ref = linked_parent_call_ref_for(call_session)
    return if parent_ref.blank? || parent_ref == call_session.external_call_ref

    call_session.conversation.messages.voice_calls.find_by(source_id: "voice_call:#{parent_ref}") ||
      call_session.conversation.messages.voice_calls.order(created_at: :desc, id: :desc).detect do |message|
        normalized_content_attributes(message).dig('data', 'call_sid') == parent_ref
      end
  end

  def linked_parent_call_ref_for(call_session)
    metadata = call_session.metadata.to_h.deep_stringify_keys
    ai_voice = metadata['ai_voice'].is_a?(Hash) ? metadata['ai_voice'] : {}
    linked_terminal = ai_voice['linked_parent_terminal'].is_a?(Hash) ? ai_voice['linked_parent_terminal'] : {}
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
    last_payload = metadata['last_payload'].is_a?(Hash) ? metadata['last_payload'] : {}
    nested_payload = last_payload['payload'].is_a?(Hash) ? last_payload['payload'] : {}

    linked_terminal['bridge_call_ref'].presence ||
      route_metadata['logical_call_group_ref'].presence ||
      route_metadata['bridge_call_ref'].presence || route_metadata['bridgeCallRef'].presence ||
      last_payload['bridge_call_ref'].presence || last_payload['bridgeCallRef'].presence ||
      nested_payload['bridge_call_ref'].presence || nested_payload['bridgeCallRef'].presence
  end

  def linked_logical_group_voice_message_for(call_session)
    logical_key = logical_call_key(call_session)
    return if logical_key.blank? || call_session.conversation.blank?

    call_session.conversation.messages.voice_calls.order(created_at: :desc, id: :desc).detect do |message|
      data = normalized_content_attributes(message).fetch('data', {})
      next false if data['call_sid'].to_s == call_session.external_call_ref
      next false unless logical_group_key_matches?(data, logical_key)

      !unanswered_terminal_status?(data['status'].to_s)
    end
  end

  def linked_unanswered_fonoster_voice_message_for(call_session)
    logical_key = logical_call_key(call_session)
    return if logical_key.blank? || call_session.conversation.blank?

    call_session.conversation.messages.voice_calls.order(:created_at, :id).detect do |message|
      data = normalized_content_attributes(message).fetch('data', {})
      next false if data['call_sid'].to_s == call_session.external_call_ref
      next false unless data['provider'].to_s == 'fonoster'
      next false unless data['call_direction'].to_s == 'inbound'
      next false unless unanswered_terminal_status?(data['status'].to_s)

      logical_group_key_matches?(data, logical_key)
    end
  end

  def remove_fonoster_group_duplicate_messages!(call_session, canonical_message)
    return unless fonoster_call_session?(call_session)
    return unless call_session.direction == 'inbound'
    return if call_session.conversation.blank? || canonical_message.blank?

    logical_key = logical_call_key(call_session)

    call_session.conversation.messages.voice_calls.where.not(id: canonical_message.id).find_each do |message|
      data = normalized_content_attributes(message).fetch('data', {})
      next unless duplicate_fonoster_group_message?(data, call_session, logical_key)
      next unless data['call_sid'].present? && data['call_sid'] != call_session.external_call_ref
      next unless unanswered_terminal_status?(data['status'].to_s)

      message.destroy!
    end
  end

  def linked_recent_context_voice_message_for(call_session)
    return if call_session.conversation.blank?

    call_session.conversation.messages.voice_calls.order(created_at: :desc, id: :desc).detect do |message|
      data = normalized_content_attributes(message).fetch('data', {})
      next false if data['call_sid'].to_s == call_session.external_call_ref
      next false if unanswered_terminal_status?(data['status'].to_s)

      duplicate_fonoster_context_message?(data, call_session, message)
    end
  end

  def duplicate_fonoster_group_message?(data, call_session, logical_key)
    return true if logical_key.present? && logical_group_key_matches?(data, logical_key)

    duplicate_fonoster_context_message?(data, call_session)
  end

  def duplicate_fonoster_context_message?(data, call_session, message = nil)
    return false unless data['provider'].to_s == 'fonoster'
    return false unless data['call_direction'].to_s == 'inbound'
    return false unless same_phone_value?(data['from_number'], call_session.from_number)
    return false unless same_phone_value?(data['to_number'], call_session.to_number)
    return true if message.blank?

    event_start = call_session.started_at || call_session.created_at
    return true if event_start.blank?

    message.created_at.between?(event_start - 90.seconds, event_start + 90.seconds)
  end

  def same_phone_value?(left, right)
    normalized_left = normalized_phone(left)
    normalized_right = normalized_phone(right)
    return false if normalized_left.blank? || normalized_right.blank?

    normalized_left == normalized_right
  end

  def logical_group_key_matches?(data, logical_key)
    [
      data['logical_call_key'],
      data['logicalCallKey'],
      data['call_group_key'],
      data['callGroupKey'],
      data.dig('meta', 'logical_call_key'),
      data.dig('meta', 'call_group_key')
    ].compact.map(&:to_s).include?(logical_key.to_s)
  end

  def exact_voice_message_for(call_session)
    call_session.exact_voice_message ||
      call_session.conversation.messages.voice_calls.order(created_at: :desc, id: :desc).detect do |message|
        normalized_content_attributes(message).dig('data', 'call_sid') == call_session.external_call_ref
      end
  end

  def build_voice_message!(call_session)
    conversation = call_session.conversation
    return if conversation.blank?

    timestamp = (call_session.started_at || call_session.created_at || Time.current).to_i
    source_id = "voice_call:#{call_session.external_call_ref}"
    message = conversation.messages.build(
      account: conversation.account,
      inbox: conversation.inbox,
      sender: voice_message_sender(call_session, conversation),
      message_type: voice_message_type(call_session),
      content: 'Voice Call',
      content_type: :voice_call,
      source_id: source_id,
      content_attributes: {
        'data' => {
          'call_sid' => call_session.external_call_ref,
          'status' => call_session.status,
          'call_direction' => call_session.direction,
          'from_number' => call_session.from_number,
          'to_number' => call_session.to_number,
          'provider' => call_session.provider,
          'inbox_id' => call_session.inbox_id,
          'meta' => {
            'created_at' => timestamp,
            'ringing_at' => timestamp
          }
        }.compact
      }
    )
    message.skip_send_reply = true if call_session.direction == 'outbound'
    message.save!
    message
  rescue ActiveRecord::RecordNotUnique
    conversation.messages.voice_calls.find_by(source_id: source_id) ||
      Message.find_by(inbox: conversation.inbox, source_id: source_id)
  end

  def voice_message_type(call_session)
    call_session.direction == 'outbound' ? :outgoing : :incoming
  end

  def communication_thread_id_for(call_session)
    conversation = call_session.conversation
    return unless conversation&.account&.feature_enabled?('communication_threads')

    (conversation.communication_thread || conversation.refresh_communication_thread!)&.display_id
  end

  def voice_message_sender(call_session, conversation)
    return conversation.contact if call_session.direction == 'inbound'

    call_session.agent_binding&.user
  end

  def voice_message_meta(call_session)
    metadata = (call_session.metadata || {}).deep_stringify_keys
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'].deep_stringify_keys : {}
    meta = route_metadata.slice(
      'operator_pool',
      'operator_pool_size',
      'operator_candidates',
      'operator_candidate_binding_ids',
      'operator_candidate_user_ids',
      'operator_candidate_agent_refs',
      'operator_candidate_agent_aors',
      'operator_internal_extension',
      'logical_call_key',
      'call_group_key'
    )
    if (logical_key = logical_call_key(call_session)).present?
      meta['logical_call_key'] = logical_key
      meta['call_group_key'] = logical_key
    end
    meta['operator_claim'] = metadata['operator_claim'] if metadata['operator_claim'].present?
    latest_leg = latest_call_leg(call_session)
    meta['latest_event_type'] = latest_leg['event_type'] if latest_leg['event_type'].present?
    meta['latest_leg'] = latest_leg['leg'] if latest_leg['leg'].present?
    meta['latest_leg_status'] = latest_leg['status'] if latest_leg['status'].present?
    meta['latest_raw_status'] = latest_leg['raw_status'] if latest_leg['raw_status'].present?
    meta.compact
  end

  def accepted_by_from_operator_claim(call_session, operator_claim)
    claim = operator_claim.is_a?(Hash) ? operator_claim.deep_stringify_keys : {}
    user_id = claim['user_id'].presence || claim['chatwoot_user_id'].presence
    user_name = claim['user_name'].presence ||
                claim['userName'].presence ||
                claim['name'].presence ||
                operator_claim_user_name(call_session, user_id)
    return if user_name.blank?

    {
      'id' => user_id,
      'name' => user_name
    }.compact
  end

  def operator_claim_user_name(call_session, user_id)
    return if user_id.blank?

    user = call_session.account.users.find_by(id: user_id)
    user&.display_name.presence || user&.name.presence || user&.email
  end

  def latest_call_leg(call_session)
    normalized_call_legs(call_session).each_with_index.max_by do |leg, index|
      [call_leg_occurred_at_timestamp(leg), index]
    end&.first || {}
  end

  def normalized_call_legs(call_session)
    call_session.legs.to_a.filter_map do |leg|
      leg.deep_stringify_keys if leg.is_a?(Hash)
    end
  end

  def call_leg_occurred_at_timestamp(leg)
    parse_time(leg['occurred_at'])&.to_f || 0
  end

  def voice_ai_message_state(call_session)
    latest_ai_event = latest_ai_event(call_session)
    ai_answered = call_session.answered_by == 'ai_agent' || ai_answered_leg?(call_session)
    enabled = ai_answered || latest_ai_event.present? || call_session.metadata.to_h['ai_voice'].present?
    return {} unless enabled

    {
      'enabled' => true,
      'answered' => ai_answered,
      'state' => voice_ai_state(call_session, latest_ai_event),
      'latest_event' => latest_ai_event&.event_type,
      'updated_at' => latest_ai_event&.created_at&.iso8601 || call_session.last_event_at&.iso8601,
      'answered_by' => call_session.answered_by,
      'timeline_messages_enabled' => true
    }.compact
  end

  def latest_ai_event(call_session)
    call_session.events.where(event_type: ai_voice_event_types).order(created_at: :desc, id: :desc).first
  end

  def ai_answered_leg?(call_session)
    call_session.legs.to_a.any? do |leg|
      leg.is_a?(Hash) && leg['event_type'] == 'ai_answered'
    end
  end

  def voice_ai_state(call_session, latest_ai_event)
    return 'completed' if call_session.terminal?
    return 'speaking' if latest_ai_event&.event_type.in?(%w[ai_speaking realtime_audio_out])
    return 'using_tool' if latest_ai_event&.event_type.in?(%w[tool_started])
    return 'answered' if call_session.status == 'in_progress'

    call_session.status
  end

  def voice_ai_tool_events(call_session)
    tool_event_types = %w[tool_started tool_progress tool_completed tool_failed tool_suppressed tool_async_completed tool_async_failed]

    rows = call_session.events.where(event_type: tool_event_types).order(:created_at, :id).last(40).filter_map do |event|
      event_payload = event.payload.to_h.deep_stringify_keys
      tool_payload = event_payload['payload'].is_a?(Hash) ? event_payload['payload'].deep_stringify_keys : {}
      metadata_payload = event_payload['metadata'].is_a?(Hash) ? event_payload['metadata'].deep_stringify_keys : {}
      tool_name = tool_payload['tool_name'] || metadata_payload['tool_name'] || event_payload['tool_name']
      next if tool_name.blank?

      tool_call_id = tool_payload['tool_call_id'] || tool_payload['toolCallId'] ||
                     metadata_payload['tool_call_id'] || metadata_payload['toolCallId']
      request_id = tool_payload['request_id'] || tool_payload['requestId'] ||
                   metadata_payload['request_id'] || metadata_payload['requestId']
      bridge_call_ref = tool_payload['bridge_call_ref'] || tool_payload['bridgeCallRef'] ||
                        metadata_payload['bridge_call_ref'] || metadata_payload['bridgeCallRef']
      runtime_call_ref = tool_payload['runtime_call_ref'] || tool_payload['runtimeCallRef'] ||
                         metadata_payload['runtime_call_ref'] || metadata_payload['runtimeCallRef'] ||
                         call_session.external_call_ref
      input_payload = tool_payload.key?('input') ? tool_payload['input'] : metadata_payload['input']
      output_payload = if tool_payload.key?('output')
                         tool_payload['output']
                       elsif tool_payload.key?('result')
                         tool_payload['result']
                       elsif metadata_payload.key?('output')
                         metadata_payload['output']
                       else
                         metadata_payload['result']
                       end

      {
        'event' => event.event_type,
        'name' => tool_name,
        'status' => tool_status(event.event_type),
        'ok' => tool_payload.key?('ok') ? tool_payload['ok'] : metadata_payload['ok'],
        'pending' => tool_payload.key?('pending') ? tool_payload['pending'] : metadata_payload['pending'],
        'async' => tool_payload.key?('async') ? tool_payload['async'] : metadata_payload['async'],
        'tool_call_id' => tool_call_id,
        'request_id' => request_id,
        'call_ref' => call_session.external_call_ref,
        'bridge_call_ref' => bridge_call_ref,
        'runtime_call_ref' => runtime_call_ref,
        'conversation_id' => call_session.conversation_id,
        'input' => input_payload,
        'output' => output_payload,
        'error' => tool_payload['error'] || metadata_payload['error'],
        'at' => parse_time(event_payload['occurred_at'] || event_payload['occurredAt'])&.iso8601 || event.created_at.iso8601
      }.compact
    end

    dedupe_tool_rows(rows).last(20)
  end

  def dedupe_tool_rows(rows)
    seen = Set.new
    rows.reverse_each.with_object([]) do |row, deduped|
      key = [row['event'], row['name'], row['tool_call_id'].presence || row['request_id'].presence || row['at']].join(':')
      next if seen.include?(key)

      seen << key
      deduped.unshift(row)
    end
  end

  def ai_voice_event_types
    %w[
      app_answered ai_ringing ai_answered media_stream_started realtime_audio_out first_audio_out_write ai_speaking caller_interrupted
      media_writer_started media_stream_framing_error tool_started tool_progress tool_completed tool_failed tool_suppressed
      tool_async_completed tool_async_failed post_tool_model_stall business_faq_gate_fired business_faq_gate_result_injected
      ordinary_answer_model_stall incomplete_answer_model_stall
    ]
  end

  def tool_status(event_type)
    case event_type
    when 'tool_started', 'tool_progress'
      'running'
    when 'tool_completed', 'tool_async_completed'
      'completed'
    when 'tool_suppressed'
      'suppressed'
    when 'tool_failed', 'tool_async_failed'
      'failed'
    end
  end

  def resolve_existing_conversation(account, call_session)
    return call_session.conversation if call_session.conversation.present?

    if (conversation_id = payload_value('conversation_id', 'conversationId')).present?
      conversation = account.conversations.find_by(id: conversation_id)
      return conversation if conversation.present?
    end

    if (conversation_id = metadata_value('chatwoot_conversation_id', 'conversation_id', 'conversationId')).present?
      conversation = account.conversations.find_by(id: conversation_id)
      return conversation if conversation.present?
    end

    if (display_id = payload_value('conversation_display_id', 'conversationDisplayId')).present?
      conversation = account.conversations.find_by(display_id: display_id)
      return conversation if conversation.present?
    end

    if (display_id = metadata_value('chatwoot_conversation_display_id', 'conversation_display_id', 'conversationDisplayId')).present?
      conversation = account.conversations.find_by(display_id: display_id)
      return conversation if conversation.present?
    end

    conversation = account.conversations.find_by(identifier: call_ref)
    return conversation if conversation.present?

    resolve_reusable_fonoster_conversation(account, call_session)
  end

  def resolve_reusable_fonoster_conversation(account, call_session)
    return unless fonoster_call_session?(call_session)

    inbox = call_session.inbox || resolve_inbox(account)
    contact = call_session.contact || resolve_contact(account, nil)
    return if inbox.blank? || contact.blank?

    reusable_fonoster_conversation(account: account, inbox: inbox, contact: contact, call_session: call_session)
  end

  def reusable_fonoster_conversation(account:, inbox:, contact:, call_session:)
    return unless fonoster_call_session?(call_session)

    account.conversations
           .where(inbox_id: inbox.id, contact_id: contact.id)
           .order(last_activity_at: :desc, id: :desc)
           .first
  end

  def fonoster_call_session?(call_session)
    provider = payload_value('provider') || call_session&.provider || 'fonoster'
    provider.to_s == 'fonoster'
  end

  def normalized_phone(value)
    digits = value.to_s.gsub(/\D/, '')
    digits = digits.delete_prefix('00')
    digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
    digits.presence
  end

  def resolve_contact(account, conversation, call_session = nil)
    return conversation.contact if conversation&.contact.present?

    contact_id = payload_value('contact_id', 'contactId') || metadata_value('chatwoot_contact_id', 'contact_id', 'contactId')
    return account.contacts.find_by(id: contact_id) if contact_id.present?

    phone_number = caller_number if resolved_direction == 'inbound'
    phone_number ||= resolved_outbound_customer_number(call_session) if resolved_direction == 'outbound' && call_session.present?
    phone_number ||= resolved_to_number if resolved_direction == 'outbound'
    return if phone_number.blank?

    account.contacts.find_by(phone_number: normalize_phone_number(phone_number) || phone_number)
  end

  def resolve_inbox(account, call_session = nil)
    return call_session.inbox if post_finalize_recording_event? && call_session&.inbox.present?

    inbox_id = payload_value('inbox_id', 'inboxId') || metadata_value('chatwoot_inbox_id', 'inbox_id', 'inboxId')
    return account.inboxes.find_by(id: inbox_id) if inbox_id.present?

    binding = resolve_number_binding(account, call_session)
    return binding.inbox if binding&.inbox.present?

    channel = Channel::Voice.find_by(phone_number: inbound_number, account_id: account.id)
    channel ||= Channel::Voice.find_by(phone_number: resolved_from_number, account_id: account.id) if resolved_direction == 'outbound'
    channel&.inbox
  end

  def resolve_number_binding(account = nil, call_session = nil)
    if post_finalize_recording_event? &&
       call_session&.number_binding.present? &&
       (account.blank? || call_session.number_binding.account_id == account.id)
      return call_session.number_binding
    end

    @resolve_number_binding_by_account ||= {}
    cache_key = account&.id || :global
    return @resolve_number_binding_by_account[cache_key] if @resolve_number_binding_by_account.key?(cache_key)

    scope = Telephony::NumberBinding.includes(:inbox, :account)
    scope = scope.where(account_id: account.id) if account.present?
    binding = if number_ref.present?
                scope.find_by(number_ref: number_ref)
              elsif inbound_number.present?
                scope.find_by(phone_number: inbound_number)
              end

    raise_number_binding_mismatch! if account.present? && binding.blank? && number_binding_exists?

    @resolve_number_binding_by_account[cache_key] = binding
  end

  def number_binding_exists?
    if number_ref.present?
      Telephony::NumberBinding.exists?(number_ref: number_ref)
    elsif inbound_number.present?
      Telephony::NumberBinding.exists?(phone_number: inbound_number)
    else
      false
    end
  end

  def raise_number_binding_mismatch!
    raise Telephony::Error.new(
      code: 'NUMBER_BINDING_ACCOUNT_MISMATCH',
      message: 'number_ref does not belong to the resolved account',
      status: :unprocessable_content
    )
  end

  def resolve_agent_binding(account)
    agent_ref = payload_value('agent_ref', 'agentRef') || metadata_value('agent_ref', 'agentRef')
    return account.telephony_agent_bindings.find_by(agent_ref: agent_ref) if agent_ref.present?

    metadata_user_id = metadata_value('chatwoot_user_id', 'user_id', 'userId')
    return if metadata_user_id.blank?

    account.telephony_agent_bindings.find_by(user_id: metadata_user_id)
  end

  def leg_snapshot(status, call_session: nil)
    {
      event_key: event_key,
      event_type: resolved_event_type,
      status: leg_status_for(status),
      leg: leg_name,
      direction: leg_direction(call_session),
      occurred_at: resolved_occurred_at&.iso8601,
      provider_call_sid: payload_value('provider_call_sid', 'providerCallSid', 'provider_call_id', 'providerCallId'),
      bridge_call_ref: bridge_call_ref,
      runtime_call_ref: runtime_call_ref,
      media_session_ref: payload_value('media_session_ref', 'mediaSessionRef'),
      stream_ref: payload_value('stream_ref', 'streamRef') || nested_payload_value('stream_ref', 'streamRef'),
      raw_status: payload_value('raw_status', 'rawStatus'),
      answered_by: resolved_answered_by || resolved_agent_actor(status),
      ended_by: resolved_ended_by,
      end_reason: resolved_end_reason
    }.compact.deep_stringify_keys
  end

  def leg_direction(call_session)
    direction = resolved_direction
    return call_session.direction if call_session.present? && preserve_existing_outbound_direction?(call_session, direction)

    direction
  end

  def leg_status_for(status)
    return 'connecting' if resolved_event_type.to_s == 'transfer_started'

    status
  end

  def leg_name
    explicit_leg = payload_value('leg', 'leg_type', 'legType') || nested_payload_value('leg', 'leg_type', 'legType')
    return explicit_leg.to_s if explicit_leg.present?

    event_name = resolved_event_type.to_s
    ai_event_names = %w[
      caller_interrupted realtime_audio_out first_audio_out_write media_stream_started provider_stream_closed provider_error
      business_faq_gate_fired business_faq_gate_result_injected ordinary_answer_model_stall incomplete_answer_model_stall
    ]
    return 'ai' if event_name.start_with?('ai_', 'tool_') || event_name.in?(ai_event_names)
    return 'operator' if event_name.start_with?('transfer_', 'operator_')
    return 'callee' if event_name.start_with?('callee_', 'customer_', 'client_')

    nil
  end

  def merged_metadata(call_session, _conversation = nil)
    base = (call_session.metadata || {}).deep_dup
    base['last_payload'] = payload
    if metadata.present?
      existing_metadata = base['metadata'].is_a?(Hash) ? base['metadata'].deep_dup : {}
      base['metadata'] = existing_metadata.deep_merge(metadata_for_merge(existing_metadata))
    end
    if recording_event_metadata.present?
      existing_recording_metadata = base['recording'].is_a?(Hash) ? base['recording'].deep_dup : {}
      base['recording'] = existing_recording_metadata.deep_merge(recording_event_metadata)
    end
    base.compact
  end

  def metadata_for_merge(existing_metadata)
    incoming_metadata = metadata.deep_stringify_keys
    preserve_sipuni_operator_leg_metadata(existing_metadata.deep_stringify_keys, incoming_metadata)
  end

  def preserve_sipuni_operator_leg_metadata(existing_metadata, incoming_metadata)
    return incoming_metadata unless sipuni_operator_leg_value?(existing_metadata, true)
    return incoming_metadata unless sipuni_operator_leg_value?(incoming_metadata, false) ||
                                    incoming_metadata['sipuni_leg_kind'].to_s == 'external'

    incoming_metadata.merge(
      'sipuni_operator_leg' => true,
      'sipuni_leg_kind' => 'operator'
    )
  end

  def sipuni_operator_leg_value?(metadata, expected)
    return false unless metadata.key?('sipuni_operator_leg')

    ActiveModel::Type::Boolean.new.cast(metadata['sipuni_operator_leg']) == expected
  end

  def logical_call_key(call_session = nil)
    payload_value('logical_call_key', 'logicalCallKey', 'call_group_key', 'callGroupKey') ||
      metadata_value('logical_call_key', 'logicalCallKey', 'call_group_key', 'callGroupKey') ||
      call_session&.metadata.to_h.dig('metadata', 'logical_call_key') ||
      call_session&.metadata.to_h.dig('metadata', 'call_group_key')
  end

  def session_logical_call_key(call_session)
    metadata = call_session&.metadata.to_h.deep_stringify_keys
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
    last_payload = metadata['last_payload'].is_a?(Hash) ? metadata['last_payload'] : {}

    route_metadata['logical_call_key'].presence ||
      route_metadata['logicalCallKey'].presence ||
      route_metadata['call_group_key'].presence ||
      route_metadata['callGroupKey'].presence ||
      last_payload['logical_call_key'].presence ||
      last_payload['logicalCallKey'].presence ||
      last_payload['call_group_key'].presence ||
      last_payload['callGroupKey'].presence
  end

  def call_recording_metadata(call_session)
    recording = call_session.metadata.to_h['recording']
    metadata = recording.is_a?(Hash) ? recording.deep_stringify_keys : {}
    return {} if metadata.blank? && !http_url?(call_session.recording_ref)

    metadata['recording_ref'] ||= call_session.recording_ref if call_session.recording_ref.present?
    metadata['recording_url'] ||= call_session.recording_ref if http_url?(call_session.recording_ref)
    metadata.compact
  end

  def presentation_recording_metadata(call_session)
    return {} if outbound_without_customer_answer?(call_session)

    metadata = call_recording_metadata(call_session).deep_dup
    return metadata if metadata.blank?

    playable_url = recording_url(call_session)
    metadata['recording_url'] = playable_url if playable_url.present?
    metadata
  end

  def recording_url(call_session)
    return if outbound_without_customer_answer?(call_session)

    external_url = external_recording_url(call_session)
    return internal_recording_url(call_session) if Telephony::ExternalRecordingPlaybackPolicy.proxy?(external_url)

    external_url || internal_recording_url(call_session)
  end

  def outbound_without_customer_answer?(call_session)
    outbound_call_for?(call_session) && !outbound_customer_answered?(call_session)
  end

  def internal_recording_url(call_session)
    Telephony::CallRecordingPlaybackUrl.path_for(
      call_session,
      storage_key: call_recording_metadata(call_session)['storage_key'].presence || call_session.recording_ref
    )
  end

  def external_recording_url(call_session)
    candidate = call_recording_metadata(call_session)['recording_url'].presence || call_session.recording_ref.presence
    return if candidate.blank?

    candidate.to_s if http_url?(candidate)
  end

  def enqueue_external_recording_cache(call_session)
    return unless call_session.terminal?
    return unless Telephony::ExternalRecordingPlaybackPolicy.proxy?(external_recording_url(call_session))

    Telephony::ExternalRecordingCacheJob.perform_later(call_session.id)
  rescue StandardError => e
    Rails.logger.warn(
      "TELEPHONY_EXTERNAL_RECORDING_CACHE_ENQUEUE_FAILED account_id=#{call_session.account_id} " \
      "call_session_id=#{call_session.id} provider=#{call_session.provider} error_class=#{e.class.name} message=#{e.message}"
    )
  end

  def http_url?(value)
    return false if value.blank?

    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  def recording_event_metadata
    return recording_ready_metadata if resolved_event_type == 'recording_ready'
    return recording_incomplete_metadata if resolved_event_type == 'recording_incomplete'
    return recording_error_metadata if recording_error_event?

    {}
  end

  def recording_ready_metadata
    import_metadata = recording_import_metadata
    recording_ready_base_metadata(import_metadata)
      .merge(recording_ready_payload_metadata)
      .merge(recording_ready_audio_metadata)
      .compact
  end

  def recording_import_metadata
    recording_import = metadata['recording_import']
    recording_import.is_a?(Hash) ? recording_import.deep_stringify_keys : {}
  end

  def recording_ready_base_metadata(import_metadata)
    {
      'source' => import_metadata.present? ? 'fonoster_import' : 'onelink_runtime',
      'ready_at' => (resolved_occurred_at || Time.current).iso8601,
      'recorded_by' => import_metadata['recorded_by'] || recording_payload_value('recorded_by', 'recordedBy'),
      'layout' => import_metadata['layout'] || recording_payload_value('layout'),
      'mode' => import_metadata['mode'] || recording_payload_value('mode'),
      'download_host' => import_metadata['download_host'],
      'import_event_key' => import_metadata['event_key']
    }
  end

  def recording_ready_payload_metadata
    {
      'recording_ref' => recording_payload_value('recording_ref', 'recordingRef', 'recording_url', 'recordingUrl'),
      'recording_url' => recording_payload_value('recording_url', 'recordingUrl'),
      'storage_key' => recording_payload_value('storage_key', 'storageKey'),
      'byte_size' => recording_payload_value('byte_size', 'byteSize', 'file_size', 'fileSize')&.to_i,
      'content_type' => recording_payload_value('content_type', 'contentType', 'mime_type', 'mimeType'),
      'sha256' => recording_payload_value('sha256', 'checksum'),
      'duration_ms' => recording_payload_value('duration_ms', 'durationMs')&.to_i,
      'duration_seconds' => recording_payload_value('duration_seconds', 'durationSeconds', 'duration')&.to_i,
      'writer' => metadata.dig('recording', 'writer'),
      'storage_provider' => metadata.dig('recording', 'storage_provider') || metadata.dig('recording', 'storageProvider')
    }
  end

  def recording_ready_audio_metadata
    {
      'sample_rate' => recording_payload_value('sample_rate', 'sampleRate')&.to_i,
      'channels' => recording_payload_value('channels')&.to_i,
      'channel_layout' => recording_payload_value('channel_layout', 'channelLayout'),
      'inbound_bytes' => recording_payload_value('inbound_bytes', 'inboundBytes')&.to_i,
      'outbound_bytes' => recording_payload_value('outbound_bytes', 'outboundBytes')&.to_i,
      'recording_status' => recording_payload_value('recording_status', 'recordingStatus'),
      'degraded' => recording_ready_degraded?,
      'missing_direction' => recording_payload_value('missing_direction', 'missingDirection'),
      'reason' => recording_payload_value('reason')
    }
  end

  def recording_ready_degraded?
    value = recording_payload_value('degraded', 'recording_degraded', 'recordingDegraded')
    return if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def recording_error_metadata
    {
      'source' => 'onelink_runtime',
      'error' => {
        'scope' => recording_payload_value('scope'),
        'code' => recording_payload_value('error_code', 'errorCode', 'code'),
        'message' => recording_payload_value('error_message', 'errorMessage', 'message'),
        'retryable' => recording_payload_value('retryable'),
        'occurred_at' => (resolved_occurred_at || Time.current).iso8601
      }.compact
    }.compact
  end

  def recording_incomplete_metadata
    {
      'source' => 'onelink_runtime',
      'recording_status' => recording_payload_value('recording_status', 'recordingStatus') || 'incomplete',
      'degraded' => recording_degraded?,
      'missing_direction' => recording_payload_value('missing_direction', 'missingDirection'),
      'reason' => recording_payload_value('reason'),
      'media_session_ref' => recording_payload_value('media_session_ref', 'mediaSessionRef'),
      'stream_ref' => recording_payload_value('stream_ref', 'streamRef'),
      'updated_at' => (resolved_occurred_at || Time.current).iso8601
    }.compact
  end

  def recording_degraded?
    value = recording_payload_value('degraded', 'recording_degraded', 'recordingDegraded')
    return true if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def recording_error_event?
    resolved_event_type == 'error' && recording_payload_value('scope') == 'recording'
  end

  def recording_payload_value(*keys)
    payload_value(*keys) || nested_payload_value(*keys)
  end

  def find_or_create_event!(account)
    account.telephony_events.find_by(event_key: event_key) || begin
      event = account.telephony_events.new(
        event_key: event_key,
        event_type: resolved_event_type,
        payload: payload
      )
      event.save!
      event
    rescue ActiveRecord::RecordNotUnique
      account.telephony_events.find_by!(event_key: event_key)
    rescue ActiveRecord::RecordInvalid => e
      raise unless uniqueness_conflict?(e.record, :event_key)

      account.telephony_events.find_by!(event_key: event_key)
    end
  end

  def persist_call_session!(account, call_session)
    save_call_session!(call_session, yield(call_session))
  rescue ActiveRecord::RecordNotUnique
    raise if provider_call_sid.blank?

    existing_call_session = account.telephony_call_sessions.find_by!(provider_call_sid: provider_call_sid)
    save_call_session!(existing_call_session, yield(existing_call_session))
  rescue ActiveRecord::RecordInvalid => e
    raise unless uniqueness_conflict?(e.record, :external_call_ref) || uniqueness_conflict?(e.record, :provider_call_sid)

    existing_call_session = if uniqueness_conflict?(e.record, :provider_call_sid) && provider_call_sid.present?
                              account.telephony_call_sessions.find_by!(provider_call_sid: provider_call_sid)
                            else
                              account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
                            end
    save_call_session!(existing_call_session, yield(existing_call_session))
  end

  def save_call_session!(call_session, attributes)
    call_session.assign_attributes(attributes)
    call_session.save!
    call_session
  end

  def uniqueness_conflict?(record, attribute)
    record&.errors&.of_kind?(attribute, :taken)
  end

  def event_key
    payload_value('event_key', 'eventKey', 'idempotency_key', 'idempotencyKey') ||
      Digest::SHA256.hexdigest(payload.except('controller', 'action').to_json)
  end

  def resolved_event_type
    payload_value('event', 'event_type', 'eventType', 'status') || 'unknown'
  end

  def call_ref
    bridge_call_ref || payload_value('call_ref', 'callRef', 'provider_call_id', 'providerCallId', 'call_sid', 'callSid', 'ref')
  end

  def provider_call_sid
    payload_value('provider_call_sid', 'providerCallSid', 'provider_call_id', 'providerCallId')
  end

  def bridge_call_ref
    payload_value('bridge_call_ref', 'bridgeCallRef', 'parent_call_ref', 'parentCallRef')
  end

  def runtime_call_ref
    payload_value('runtime_call_ref', 'runtimeCallRef', 'child_call_ref', 'childCallRef', 'ai_runtime_call_ref', 'aiRuntimeCallRef') ||
      payload_value('call_ref', 'callRef')
  end

  def resolved_status
    event_name = payload_value('event', 'event_type', 'eventType').to_s.strip.downcase
    if event_name == 'dial_status'
      dial_status = nested_payload_value('status', 'callStatus').to_s.strip.downcase
      return normalize_status(dial_status) if dial_status.present?
    elsif event_name == 'transfer_result'
      transfer_result = nested_payload_value('result', 'status').to_s.strip.downcase
      return normalize_status(transfer_result) if transfer_result.present?
    elsif event_name == 'call_ended'
      ended_reason = resolved_end_reason.to_s.strip.downcase
      return 'cancelled' if %w[caller_hangup caller_hung_up].include?(ended_reason)
    elsif event_name == 'session_completed' && missed_inbound_terminal_reason?
      return 'missed'
    elsif EVENT_STATUS_MAP.key?(event_name) && EVENT_STATUS_MAP[event_name].present?
      return normalize_status(event_name)
    end

    explicit = payload_value('status').to_s.strip.downcase
    return normalize_status(explicit) if explicit.present?

    normalize_status(event_name)
  end

  def normalize_status(raw_status)
    mapped = EVENT_STATUS_MAP[raw_status]
    Telephony::CallSession.normalize_status(mapped || raw_status)
  end

  def resolved_direction
    value = payload_value('direction', 'call_direction', 'callDirection').to_s.strip.downcase
    return 'inbound' if %w[inbound from_pstn].include?(value)
    return 'outbound' if %w[outbound to_pstn outbound_api outbound-dial outbound_api_call].include?(value)

    value.presence_in(Telephony::CallSession::ALLOWED_DIRECTIONS)
  end

  def missed_inbound_terminal_reason?
    return false unless resolved_end_reason.to_s.strip.downcase.in?(MISSED_INBOUND_TERMINAL_REASONS)

    resolved_direction != 'outbound'
  end

  def resolved_from_number
    value = payload_value('caller_number', 'callerNumber', 'from_number', 'fromNumber', 'from')
    normalize_phone_number(value) || value
  end

  def resolved_to_number
    value = payload_value('callee_number', 'calleeNumber', 'to_number', 'toNumber', 'to') || inbound_number
    normalize_phone_number(value) || value
  end

  def number_ref
    payload_value('number_ref', 'numberRef')
  end

  def inbound_number
    payload_value('ingress_number', 'ingressNumber', 'to_number', 'toNumber', 'to')
  end

  def caller_number
    value = payload_value('caller_number', 'callerNumber', 'from_number', 'fromNumber', 'from')
    normalize_phone_number(value) || value
  end

  def normalized_caller_number
    normalize_phone_number(caller_number)
  end

  def normalize_phone_number(value)
    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ')
  end

  def event_time
    resolved_occurred_at || Time.current
  end

  def default_started_at(status)
    event_time if %w[created ringing connecting in_progress].include?(status)
  end

  def resolved_duration
    duration = payload_value('duration', 'call_duration', 'callDuration') || nested_payload_value('duration')
    duration ||= duration_ms / 1000 if duration_ms&.positive?
    duration&.to_i
  end

  def duration_ms
    value = payload_value('duration_ms', 'durationMs') || nested_payload_value('duration_ms', 'durationMs')
    value.to_i if value.present?
  end

  def resolved_started_at
    parse_time(payload_value('started_at', 'startedAt')) ||
      parse_time(nested_payload_value('started_at', 'startedAt'))
  end

  def resolved_answered_at
    parse_time(payload_value('answered_at', 'answeredAt')) ||
      parse_time(nested_payload_value('answered_at', 'answeredAt'))
  end

  def resolved_answered_by
    payload_value('answered_by', 'answeredBy') ||
      nested_payload_value('answered_by', 'answeredBy') ||
      metadata_value('answered_by', 'answeredBy', 'agent_ref', 'agentRef', 'chatwoot_user_id')
  end

  def resolved_agent_actor(status)
    return unless status == 'in_progress'
    return 'ai_agent' if resolved_event_type.to_s == 'ai_answered'

    agent_ref = payload_value('agent_ref', 'agentRef') || metadata_value('agent_ref', 'agentRef')
    user_id = metadata_value('chatwoot_user_id', 'user_id', 'userId')
    agent_ref.presence || ("user:#{user_id}" if user_id.present?)
  end

  def resolved_ended_at
    parse_time(payload_value('ended_at', 'endedAt')) ||
      parse_time(nested_payload_value('ended_at', 'endedAt'))
  end

  def resolved_ended_by
    payload_value('ended_by', 'endedBy') ||
      nested_payload_value('ended_by', 'endedBy') ||
      metadata_value('ended_by', 'endedBy')
  end

  def resolved_end_reason
    payload_value('end_reason', 'endReason', 'hangup_reason', 'hangupReason', 'reason') ||
      nested_payload_value('end_reason', 'endReason', 'hangup_reason', 'hangupReason', 'reason') ||
      metadata_value('end_reason', 'endReason', 'hangup_reason', 'hangupReason', 'reason')
  end

  def resolved_occurred_at
    parse_time(payload_value('occurred_at', 'occurredAt')) ||
      parse_time(payload_value('received_at', 'receivedAt')) ||
      parse_time(payload_value('created_at', 'createdAt')) ||
      resolved_ended_at
  end

  def metadata
    value = payload['metadata'] || payload['payload']&.dig('metadata')
    return value if value.is_a?(Hash)

    {}
  end

  def metadata_value(*keys)
    keys.each do |key|
      value = metadata[key.to_s]
      return value if value.present?
    end

    nil
  end

  def resolve_metadata_conversation
    conversation_id = metadata_value('chatwoot_conversation_id', 'conversation_id', 'conversationId')
    return if conversation_id.blank?

    ::Conversation.find_by(id: conversation_id)
  end

  def resolve_payload_conversation
    conversation_id = payload_value('conversation_id', 'conversationId')
    return if conversation_id.blank?

    ::Conversation.find_by(id: conversation_id)
  end

  def resolve_metadata_inbox
    inbox_id = metadata_value('chatwoot_inbox_id', 'inbox_id', 'inboxId')
    return if inbox_id.blank?

    ::Inbox.find_by(id: inbox_id)
  end

  def resolve_metadata_contact
    contact_id = metadata_value('chatwoot_contact_id', 'contact_id', 'contactId')
    return if contact_id.blank?

    ::Contact.find_by(id: contact_id)
  end

  def payload_value(*keys)
    keys.each do |key|
      value = payload[key.to_s]
      return value if value.present?
    end

    nil
  end

  def truthy_payload_value?(*keys)
    keys.any? do |key|
      value = payload[key.to_s]
      value == true || value.to_s.strip.downcase.in?(%w[true 1 yes])
    end
  end

  def nested_payload_value(*keys)
    nested = payload['payload']
    return nil unless nested.is_a?(Hash)

    keys.each do |key|
      value = nested[key.to_s]
      return value if value.present?
    end

    nil
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
