require 'digest'

class Telephony::EventsIngestionService
  CALL_SESSION_CONFLICT_RETRIES = 2

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
    'ai_speaking' => nil,
    'caller_interrupted' => nil,
    'ringing' => 'ringing',
    'answered' => 'in_progress',
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
      "FONOSTER_VOICE_EVENT_SIDE_EFFECT_ERROR event_id=#{event.id} account_id=#{event.account_id} " \
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
    end
  end

  def process_event!(account, event)
    call_session = nil

    ActiveRecord::Base.transaction do
      event.lock!
      if event.processed? && event.call_session.present?
        call_session = event.call_session
        next
      end

      call_session = resolve_call_session!(account)
      call_session.with_lock do
        call_session = upsert_call_session!(call_session, account)
        event.update!(call_session: call_session, status: 'processed', processed_at: Time.current, error_message: nil)
      end
    end

    run_side_effects!(call_session, account, event) if call_session.present?
    call_session
  end

  def run_side_effects!(call_session, account, event)
    ensure_conversation!(call_session, account)
    apply_call_status!(call_session)
    sync_voice_message!(call_session)
  rescue StandardError => e
    event.update(status: 'failed', error_message: e.message)
    Rails.logger.error(
      "FONOSTER_VOICE_EVENT_SIDE_EFFECT_ERROR event_id=#{event.id} account_id=#{event.account_id} " \
      "event_type=#{event.event_type} call_ref=#{call_session.external_call_ref} error_class=#{e.class.name} message=#{e.message}"
    )
    call_session
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

    channel = Channel::Voice.find_by(phone_number: inbound_number)
    return channel.account if channel.present?

    raise Telephony::Error.new(code: 'ACCOUNT_NOT_FOUND', message: 'Unable to resolve account for telephony event', status: :not_found)
  end

  def resolve_call_session!(account)
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if call_ref.blank?

    account.telephony_call_sessions.find_by(external_call_ref: call_ref) ||
      account.telephony_call_sessions.create_or_find_by!(external_call_ref: call_ref)
  rescue ActiveRecord::RecordInvalid => e
    raise unless uniqueness_conflict?(e.record, :external_call_ref)

    account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def upsert_call_session!(call_session, account)
    persist_call_session!(account, call_session) do |current_call_session|
      call_session_attributes(account, current_call_session)
    end
  end

  def call_session_attributes(account, call_session)
    conversation = resolve_existing_conversation(account, call_session)
    inbox = resolve_inbox(account)
    number_binding = resolve_number_binding(account) || inbox&.telephony_number_binding
    contact = resolve_contact(account, conversation)
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
      direction: resolved_direction || call_session.direction || 'inbound',
      from_number: resolved_from_number || call_session.from_number,
      to_number: resolved_to_number || call_session.to_number,
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
      metadata: merged_metadata(call_session)
    }
  end

  def next_status_for(call_session)
    status = resolved_status
    return call_session.status if status.blank?
    return call_session.status if stale_event?(call_session)
    return call_session.status if call_session.terminal? && !terminal_status?(status)

    status
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

  def next_duration_seconds(call_session, status, started_at, answered_at, ended_at)
    return call_session.duration_seconds if stale_event?(call_session)

    explicit_duration = resolved_duration
    return explicit_duration if explicit_duration.present?
    return call_session.duration_seconds if call_session.duration_seconds.present? || !terminal_status?(status)

    duration_start = answered_at || started_at
    return if duration_start.blank? || ended_at.blank?

    [ended_at.to_i - duration_start.to_i, 0].max
  end

  def next_legs(call_session, status)
    legs = Array.wrap(call_session.legs).map { |leg| leg.is_a?(Hash) ? leg.deep_stringify_keys : leg }
    return legs if legs.any? { |leg| leg.is_a?(Hash) && leg['event_key'] == event_key }

    legs + [leg_snapshot(status)]
  end

  def next_last_event_at(call_session)
    occurred_at = resolved_occurred_at
    return call_session.last_event_at if stale_event?(call_session)
    return [call_session.last_event_at, occurred_at].compact.max if occurred_at.present?

    Time.current
  end

  def stale_event?(call_session)
    occurred_at = resolved_occurred_at
    return false if occurred_at.present? && terminal_status?(resolved_status) && !call_session.terminal?

    occurred_at.present? && call_session.last_event_at.present? && occurred_at < call_session.last_event_at
  end

  def terminal_status?(status)
    Telephony::CallSession::TERMINAL_STATUSES.include?(status)
  end

  def ensure_conversation!(call_session, account)
    return if call_session.conversation.present?
    return unless call_session.direction == 'inbound'

    inbox = call_session.inbox || resolve_inbox(account)
    if inbox.blank?
      raise Telephony::Error.new(code: 'VOICE_INBOX_NOT_FOUND', message: 'Unable to resolve voice inbox for inbound call',
                                 status: :not_found)
    end

    conversation = Voice::InboundCallBuilder.perform!(
      account: account,
      inbox: inbox,
      from_number: caller_number,
      call_sid: call_ref
    )

    call_session.update!(
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      number_binding: inbox.telephony_number_binding || call_session.number_binding
    )
  end

  def apply_call_status!(call_session)
    conversation = call_session.conversation
    return unless conversation.present? && resolved_status.present?

    timestamp = call_session.ended_at&.to_i || call_session.started_at&.to_i
    Voice::CallStatus::Manager.new(
      conversation: conversation,
      call_sid: call_session.external_call_ref
    ).process_status_update(
      call_session.status,
      duration: call_session.duration_seconds,
      timestamp: timestamp
    )

    attrs = (conversation.additional_attributes || {}).deep_dup
    attrs['telephony_provider'] = call_session.provider
    attrs['recording_ref'] = call_session.recording_ref if call_session.recording_ref.present?
    attrs['transcript_ref'] = call_session.transcript_ref if call_session.transcript_ref.present?
    attrs['summary'] = call_session.summary if call_session.summary.present?
    conversation.update!(additional_attributes: attrs, last_activity_at: Time.current)
  end

  def sync_voice_message!(call_session)
    message = call_session.latest_voice_message
    return unless message

    data = (message.content_attributes || {}).deep_dup
    data['data'] ||= {}
    voice_meta = voice_message_meta(call_session)
    if voice_meta.present?
      existing_meta = data['data']['meta'].is_a?(Hash) ? data['data']['meta'] : {}
      data['data']['meta'] = existing_meta.merge(voice_meta)
    end
    data['data']['status'] = call_session.status
    existing_ai_voice = data['data']['ai_voice'].is_a?(Hash) ? data['data']['ai_voice'] : {}
    data['data']['ai_voice'] = existing_ai_voice.merge(voice_ai_message_state(call_session))
    tools = voice_ai_tool_events(call_session)
    data['data']['tools'] = tools if tools.present?
    data['data']['recording_ref'] = call_session.recording_ref if call_session.recording_ref.present?
    data['data']['transcript_ref'] = call_session.transcript_ref if call_session.transcript_ref.present?
    transcript = payload_value('transcript')
    data['data']['transcript'] = transcript if transcript.present?
    data['data']['summary'] = call_session.summary if call_session.summary.present?
    data['data']['duration'] = call_session.duration_seconds if call_session.duration_seconds.present?
    message.update!(content_attributes: data)
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
      'operator_candidate_agent_aors'
    )
    meta['operator_claim'] = metadata['operator_claim'] if metadata['operator_claim'].present?
    meta.compact
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
    tool_event_types = %w[tool_started tool_progress tool_completed tool_failed]

    call_session.events.where(event_type: tool_event_types).order(:created_at, :id).last(20).filter_map do |event|
      event_payload = event.payload.to_h.deep_stringify_keys
      tool_payload = event_payload['payload'].is_a?(Hash) ? event_payload['payload'].deep_stringify_keys : {}
      metadata_payload = event_payload['metadata'].is_a?(Hash) ? event_payload['metadata'].deep_stringify_keys : {}
      tool_name = tool_payload['tool_name'] || metadata_payload['tool_name'] || event_payload['tool_name']
      next if tool_name.blank?

      {
        'event' => event.event_type,
        'name' => tool_name,
        'status' => tool_status(event.event_type),
        'ok' => tool_payload.key?('ok') ? tool_payload['ok'] : metadata_payload['ok'],
        'error' => tool_payload['error'] || metadata_payload['error'],
        'at' => parse_time(event_payload['occurred_at'] || event_payload['occurredAt'])&.iso8601 || event.created_at.iso8601
      }.compact
    end
  end

  def ai_voice_event_types
    %w[
      app_answered ai_ringing ai_answered media_stream_started realtime_audio_out ai_speaking caller_interrupted
      tool_started tool_progress tool_completed tool_failed
    ]
  end

  def tool_status(event_type)
    case event_type
    when 'tool_started', 'tool_progress'
      'running'
    when 'tool_completed'
      'completed'
    when 'tool_failed'
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

    account.conversations.find_by(identifier: call_ref)
  end

  def resolve_contact(account, conversation)
    return conversation.contact if conversation&.contact.present?

    contact_id = payload_value('contact_id', 'contactId') || metadata_value('chatwoot_contact_id', 'contact_id', 'contactId')
    return account.contacts.find_by(id: contact_id) if contact_id.present?

    phone_number = caller_number if resolved_direction == 'inbound'
    phone_number ||= resolved_to_number if resolved_direction == 'outbound'
    return if phone_number.blank?

    account.contacts.find_by(phone_number: phone_number)
  end

  def resolve_inbox(account)
    inbox_id = payload_value('inbox_id', 'inboxId') || metadata_value('chatwoot_inbox_id', 'inbox_id', 'inboxId')
    return account.inboxes.find_by(id: inbox_id) if inbox_id.present?

    binding = resolve_number_binding(account)
    return binding.inbox if binding&.inbox.present?

    channel = Channel::Voice.find_by(phone_number: inbound_number, account_id: account.id)
    channel&.inbox
  end

  def resolve_number_binding(account = nil)
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

  def leg_snapshot(status)
    {
      event_key: event_key,
      event_type: resolved_event_type,
      status: leg_status_for(status),
      leg: leg_name,
      direction: resolved_direction,
      occurred_at: resolved_occurred_at&.iso8601,
      provider_call_sid: payload_value('provider_call_sid', 'providerCallSid', 'provider_call_id', 'providerCallId'),
      answered_by: resolved_answered_by || resolved_agent_actor(status),
      ended_by: resolved_ended_by,
      end_reason: resolved_end_reason
    }.compact.deep_stringify_keys
  end

  def leg_status_for(status)
    return 'connecting' if resolved_event_type.to_s == 'transfer_started'

    status
  end

  def leg_name
    event_name = resolved_event_type.to_s
    ai_event_names = %w[caller_interrupted realtime_audio_out media_stream_started provider_stream_closed provider_error]
    return 'ai' if event_name.start_with?('ai_', 'tool_') || event_name.in?(ai_event_names)
    return 'operator' if event_name.start_with?('transfer_', 'operator_')

    nil
  end

  def merged_metadata(call_session)
    base = (call_session.metadata || {}).deep_dup
    base['last_payload'] = payload
    if metadata.present?
      existing_metadata = base['metadata'].is_a?(Hash) ? base['metadata'].deep_dup : {}
      base['metadata'] = existing_metadata.deep_merge(metadata)
    end
    base.compact
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
  rescue ActiveRecord::RecordInvalid => e
    raise unless uniqueness_conflict?(e.record, :external_call_ref)

    existing_call_session = account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
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
    payload_value('call_ref', 'callRef', 'provider_call_id', 'providerCallId', 'call_sid', 'callSid', 'ref')
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
      ended_reason = nested_payload_value('reason', 'end_reason', 'endReason').to_s.strip.downcase
      return 'cancelled' if ended_reason == 'caller_hung_up'
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
    value = payload_value('direction').to_s.strip.downcase
    return 'inbound' if %w[inbound from_pstn].include?(value)
    return 'outbound' if %w[outbound outbound_api outbound-dial outbound_api_call].include?(value)

    value.presence_in(Telephony::CallSession::ALLOWED_DIRECTIONS)
  end

  def resolved_from_number
    payload_value('caller_number', 'callerNumber', 'from_number', 'fromNumber', 'from')
  end

  def resolved_to_number
    payload_value('callee_number', 'calleeNumber', 'to_number', 'toNumber', 'to') || inbound_number
  end

  def number_ref
    payload_value('number_ref', 'numberRef')
  end

  def inbound_number
    payload_value('ingress_number', 'ingressNumber', 'to_number', 'toNumber', 'to')
  end

  def caller_number
    payload_value('caller_number', 'callerNumber', 'from_number', 'fromNumber', 'from')
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
      parse_time(payload_value('created_at', 'createdAt'))
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
