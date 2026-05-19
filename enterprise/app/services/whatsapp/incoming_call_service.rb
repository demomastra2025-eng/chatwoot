class Whatsapp::IncomingCallService
  FAILURE_REASONS = %w[failed error rejected busy invalid_offer cancelled canceled].freeze
  RINGING_CLEANUP_DELAY = 60.seconds

  def self.outbound_connect_cache_key(account_id, provider_call_id)
    "whatsapp:outbound_connect:#{account_id}:#{provider_call_id}"
  end

  def self.cache_outbound_connect(account_id:, call_payload:)
    provider_call_id = call_payload[:id]
    return if provider_call_id.blank?

    Redis::Alfred.set(
      outbound_connect_cache_key(account_id, provider_call_id),
      call_payload.to_h.to_json,
      ex: 2.minutes.to_i
    )
  end

  def self.pop_cached_outbound_connect(account_id:, provider_call_id:)
    key = outbound_connect_cache_key(account_id, provider_call_id)
    payload = Redis::Alfred.get(key)
    Redis::Alfred.delete(key) if payload.present?
    JSON.parse(payload).with_indifferent_access if payload.present?
  rescue JSON::ParserError
    Redis::Alfred.delete(key)
    nil
  end

  pattr_initialize [:inbox!, :params!]

  def perform
    return unless calling_enabled?

    Array(params[:calls]).each { |call_payload| handle_call_event(call_payload.with_indifferent_access) }
    Array(params[:statuses]).each { |status_payload| handle_call_status(status_payload.with_indifferent_access) }
  end

  private

  def calling_enabled?
    channel = inbox.channel
    return channel.voice_enabled? if channel.respond_to?(:voice_enabled?)

    inbox.account.feature_enabled?('whatsapp_call')
  end

  def handle_call_event(call_payload)
    case call_payload[:event]
    when 'connect' then handle_call_connect(call_payload)
    when 'terminate' then handle_call_terminate(call_payload)
    else Rails.logger.warn "[WHATSAPP CALL] Unknown call event: #{call_payload[:event]}"
    end
  end

  # Meta sends outbound pickup as a status webhook. The `connect` event only
  # means the WebRTC tunnel is ready and can arrive before the contact answers.
  def handle_call_status(status_payload)
    return unless status_payload[:type] == 'call'

    call = Call.whatsapp.find_by(provider_call_id: status_payload[:id])
    return unless call

    case status_payload[:status]
    when 'ACCEPTED' then mark_outbound_accepted(call, status_payload)
    when 'RINGING' then nil
    else Rails.logger.info "[WHATSAPP CALL] Unhandled call status: #{status_payload[:status]} for #{status_payload[:id]}"
    end
  end

  def mark_outbound_accepted(call, status_payload)
    transitioned = false

    call.with_lock do
      call.reload
      if call.outgoing? && !call.in_progress? && !call.terminal?
        started_at = status_timestamp(status_payload) || Time.current
        call.update!(status: 'in_progress', started_at: started_at)
        transitioned = true
      end
    end

    return unless transitioned

    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: call.accepted_by_agent)
    update_conversation_call_status(call.conversation, 'in-progress', call.direction_label)
    broadcast_outbound_accepted(call)
  end

  def handle_call_connect(call_payload)
    provider_call_id = call_payload[:id]
    call = Call.whatsapp.find_by(provider_call_id: provider_call_id)

    if call.nil?
      return create_inbound_call(call_payload) if inbound_offer?(call_payload)

      cache_unknown_outbound_connect(call_payload)
      Rails.logger.warn "[WHATSAPP CALL] Outbound connect for unknown call #{provider_call_id}; skipping"
      return
    end

    return handle_outbound_connect(call, call_payload) if call.outgoing?

    Rails.logger.info "[WHATSAPP CALL] Duplicate inbound connect for #{provider_call_id}; ignoring"
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.warn "[WHATSAPP CALL] Duplicate provider_call_id received: #{provider_call_id}"
  end

  def inbound_offer?(call_payload)
    call_payload.dig(:session, :sdp_type).to_s.downcase == 'offer'
  end

  def cache_unknown_outbound_connect(call_payload)
    return unless call_payload.dig(:session, :sdp_type).to_s.downcase == 'answer'
    return if call_payload.dig(:session, :sdp).blank?

    self.class.cache_outbound_connect(account_id: inbox.account_id, call_payload: call_payload)
  end

  def create_inbound_call(call_payload)
    contact = find_or_create_contact("+#{call_payload[:from]}")
    return unless contact

    conversation = find_or_create_conversation(contact)
    return unless conversation

    call = create_call_record(call_payload, conversation, contact, :incoming)
    schedule_call_cleanup(call)
    routing_decision = Whatsapp::CallRoutingService.new(call: call).perform
    persist_routing_decision(call, routing_decision)
    create_voice_call_message(conversation, call)

    if routing_decision.ai?
      handle_ai_voice_call(call, contact, call_payload, routing_decision)
    else
      prepare_inbound_media_session(call) if call.media_server_enabled?
      update_conversation_call_status(conversation, 'ringing', call.direction_label)
      broadcast_incoming_call(call, contact, call_payload.dig(:session, :sdp))
    end
  end

  def prepare_inbound_media_session(call)
    return if call.media_session_id.present?

    client = Whatsapp::MediaServerClient.new
    session_response = client.create_session(
      call_id: call.provider_call_id,
      direction: 'incoming',
      sdp_offer: call.sdp_offer,
      ice_servers: call.ice_servers,
      account_id: call.account_id
    )
    media_session_id = session_response['session_id']
    agent_offer = client.generate_agent_offer(media_session_id)
    call.update!(
      media_session_id: media_session_id,
      meta: (call.meta || {}).merge(
        'media_sdp_answer' => session_response['meta_sdp_answer'],
        'agent_offer' => agent_offer,
        'agent_offer_generated_at' => Time.zone.now.to_i
      )
    )
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.error "[WHATSAPP CALL] early inbound media prepare failed for #{call.provider_call_id}: #{e.message}"
  end

  def handle_outbound_connect(call, call_payload)
    sdp_answer = fix_sdp_setup(call_payload.dig(:session, :sdp))
    if sdp_answer.blank?
      Rails.logger.warn "[WHATSAPP CALL] Outbound connect for #{call.provider_call_id} missing SDP answer"
      return
    end

    stored = false
    should_set_meta_answer = false
    should_generate_agent_offer = false

    call.with_lock do
      call.reload
      unless call.terminal?
        meta = call.meta || {}
        if meta['sdp_answer'].blank?
          call.update!(meta: meta.merge('sdp_answer' => sdp_answer))
          stored = true
        end
        should_set_meta_answer = call.media_session_id.present? && call.meta&.dig('meta_answer_set_at').blank?
        should_generate_agent_offer = call.media_session_id.present? && call.meta&.dig('agent_offer_generated_at').blank?
        sdp_answer = call.meta&.dig('sdp_answer') || sdp_answer
      end
    end

    if call.media_session_id.present?
      finalize_outbound_server_relay(call, sdp_answer, generate_agent_offer: should_generate_agent_offer) if should_set_meta_answer
    elsif stored
      broadcast_outbound_call_connected(call, sdp_answer)
    end
  end

  def mark_agent_offer_generated(call)
    call.with_lock do
      call.reload
      call.update!(meta: (call.meta || {}).merge('agent_offer_generated_at' => Time.zone.now.to_i)) unless call.terminal?
    end
  end

  def mark_meta_answer_set(call)
    call.with_lock do
      call.reload
      call.update!(meta: (call.meta || {}).merge('meta_answer_set_at' => Time.zone.now.to_i)) unless call.terminal?
    end
  end

  def create_voice_call_message(conversation, call, user: nil)
    message = Whatsapp::CallMessageBuilder.create!(conversation: conversation, call: call, user: user)
    call.update!(message_id: message.id)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to create voice_call message: #{e.message}"
  end

  def create_call_record(call_payload, conversation, contact, direction)
    Call.create!(
      provider: :whatsapp,
      account: inbox.account,
      inbox: inbox,
      conversation: conversation,
      contact: contact,
      provider_call_id: call_payload[:id],
      direction: direction,
      status: 'ringing',
      meta: { 'sdp_offer' => call_payload.dig(:session, :sdp), 'ice_servers' => default_ice_servers }
    )
  end

  def schedule_call_cleanup(call)
    Whatsapp::CallCleanupJob.set(wait: RINGING_CLEANUP_DELAY).perform_later(call.id)
  end

  def handle_ai_voice_call(call, contact, call_payload, routing_decision)
    update_conversation_call_status(call.conversation, 'ai_accepting', call.direction_label)
    broadcast_ai_accepting_call(call, routing_decision)
    Whatsapp::AiVoiceCallService.new(call: call, routing_decision: routing_decision).perform
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] AI voice auto-answer failed for #{call.provider_call_id}: #{e.class} #{e.message}"
    mark_ai_voice_fallback(call, routing_decision, e)
    call.reload
    if call.ringing?
      update_conversation_call_status(call.conversation, 'ringing', call.direction_label)
      broadcast_incoming_call(call, contact, call_payload.dig(:session, :sdp))
    else
      update_conversation_call_status(call.conversation, 'ai_failed', call.direction_label)
      broadcast_call_ended(call) if call.terminal?
    end
  end

  def mark_ai_voice_fallback(call, routing_decision, error)
    ai_voice = {
      'state' => 'failed',
      'fallback' => 'human_ring',
      'captain_assistant_id' => routing_decision.assistant&.id,
      'runtime_transport' => 'whatsapp_cloud',
      'error_class' => error.class.name,
      'error_message' => error.message,
      'updated_at' => Time.current.iso8601
    }.compact

    call.with_lock do
      call.reload
      call.update!(status: 'ringing', meta: (call.meta || {}).merge('ai_voice' => ai_voice)) unless call.terminal?
    end
  end

  def persist_routing_decision(call, routing_decision)
    routing = {
      'action' => routing_decision.action,
      'reason' => routing_decision.reason,
      'conversation_status' => routing_decision.conversation_status,
      'captain_assistant_id' => routing_decision.assistant&.id
    }.compact

    call.update!(meta: (call.meta || {}).merge('routing' => routing))
  end

  def handle_call_terminate(call_payload)
    call = Call.whatsapp.find_by(provider_call_id: call_payload[:id])
    if call.nil?
      Rails.logger.warn "[WHATSAPP CALL] Terminate for unknown call #{call_payload[:id]}; skipping"
      return
    end

    final_status = nil
    duration = call_payload[:duration]&.to_i
    end_reason = call_payload[:terminate_reason].to_s
    transitioned = false

    call.with_lock do
      call.reload
      unless call.terminal?
        final_status = derive_terminate_status(call, duration, end_reason)
        call.update!(
          status: final_status,
          duration_seconds: duration,
          end_reason: end_reason,
          meta: (call.meta || {}).merge('ended_at' => Time.zone.now.to_i)
        )
        transitioned = true
      end
    end

    return unless transitioned

    agent = call.accepted_by_agent if call.accepted_by_agent_id.present?
    Whatsapp::CallMessageBuilder.update_status!(call: call, status: final_status, agent: agent, duration_seconds: duration)
    mapped = Whatsapp::CallMessageBuilder::CALL_TO_VOICE_STATUS[final_status] || final_status
    update_conversation_call_status(call.conversation, mapped, call.direction_label)
    broadcast_call_ended(call)
    Whatsapp::CallRecordingFetchJob.perform_later(call.id) if call.media_session_id.present?
  end

  def derive_terminate_status(call, duration, reason)
    normalized_reason = reason.to_s.downcase
    return 'failed' if FAILURE_REASONS.any? { |failure_reason| normalized_reason.include?(failure_reason) }

    answered?(call, duration) ? 'completed' : 'no_answer'
  end

  # For outbound calls, accepted_by_agent_id is the initiating agent, not proof
  # that the WhatsApp contact answered.
  def answered?(call, duration)
    call.in_progress? || duration.to_i.positive? || (call.incoming? && call.accepted_by_agent_id.present?)
  end

  def find_or_create_contact(phone_number)
    waid = phone_number.delete('+')

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: waid,
      inbox: inbox,
      contact_attributes: {
        name: phone_number,
        phone_number: phone_number
      }
    ).perform

    contact_inbox&.contact
  end

  def find_or_create_conversation(contact)
    contact_inbox = contact.contact_inboxes.find_by(inbox: inbox)
    return unless contact_inbox

    conversation = contact_inbox.conversations.where.not(status: :resolved).last
    return conversation if conversation

    ::Conversation.create!(
      account_id: inbox.account_id,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { channel: 'whatsapp' }
    )
  end

  def update_conversation_call_status(conversation, call_status, direction)
    attrs = (conversation.additional_attributes || {}).merge(
      'call_status' => call_status,
      'call_direction' => direction
    )
    conversation.update!(additional_attributes: attrs)
  end

  def broadcast_incoming_call(call, contact, sdp_offer)
    media_server_enabled = Call.media_server_enabled?(inbox: inbox)
    data = {
      account_id: inbox.account_id,
      id: call.id,
      call_id: call.provider_call_id,
      direction: call.direction_label,
      inbox_id: call.inbox_id,
      conversation_id: call.conversation_id,
      conversation_display_id: call.conversation&.display_id,
      media_session_id: call.media_session_id,
      media_server_enabled: media_server_enabled,
      caller: {
        name: contact.name,
        phone: contact.phone_number,
        avatar: contact.avatar_url
      }
    }

    if media_server_enabled && call.meta&.dig('agent_offer', 'sdp_offer').present?
      data[:agent_offer] = call.meta['agent_offer'].slice('sdp_offer', 'ice_servers')
    end

    unless media_server_enabled
      data[:sdp_offer] = sdp_offer
      data[:ice_servers] = default_ice_servers
    end

    ActionCable.server.broadcast("account_#{inbox.account_id}", { event: 'whatsapp_call.incoming', data: data })
  end

  def broadcast_ai_accepting_call(call, routing_decision)
    data = {
      account_id: inbox.account_id,
      id: call.id,
      call_id: call.provider_call_id,
      direction: call.direction_label,
      inbox_id: call.inbox_id,
      conversation_id: call.conversation_id,
      conversation_display_id: call.conversation&.display_id,
      routing_reason: routing_decision.reason,
      captain_assistant_id: routing_decision.assistant&.id
    }.compact

    ActionCable.server.broadcast("account_#{inbox.account_id}", { event: 'whatsapp_call.ai_accepting', data: data })
  end

  def broadcast_call_ended(call)
    payload = {
      event: 'whatsapp_call.ended',
      data: {
        account_id: inbox.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        status: call.status,
        duration_seconds: call.duration_seconds,
        conversation_id: call.conversation_id
      }
    }

    ActionCable.server.broadcast("account_#{inbox.account_id}", payload)
  end

  def broadcast_outbound_call_connected(call, sdp_answer)
    payload = {
      event: 'whatsapp_call.outbound_connected',
      data: {
        account_id: inbox.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        conversation_id: call.conversation_id,
        sdp_answer: sdp_answer
      }
    }

    ActionCable.server.broadcast("account_#{inbox.account_id}", payload)
  end

  def broadcast_outbound_accepted(call)
    payload = {
      event: 'whatsapp_call.outbound_accepted',
      data: {
        account_id: inbox.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        conversation_id: call.conversation_id,
        status: 'in-progress'
      }
    }

    ActionCable.server.broadcast("account_#{inbox.account_id}", payload)
  end

  # Server-relay outbound: deliver Meta's SDP answer to the media server so it
  # completes Peer A. Agent Peer B may already be pre-created from /initiate;
  # only generate/broadcast a fallback offer for older tabs/calls that do not
  # have an early browser leg.
  def finalize_outbound_server_relay(call, sdp_answer, generate_agent_offer: true)
    client = Whatsapp::MediaServerClient.new
    client.set_meta_answer(call.media_session_id, sdp_answer: sdp_answer)
    mark_meta_answer_set(call)
    return unless generate_agent_offer

    agent_offer = client.generate_agent_offer(call.media_session_id)

    payload = {
      event: 'whatsapp_call.outbound_connected',
      data: {
        account_id: inbox.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        conversation_id: call.conversation_id,
        sdp_offer: agent_offer['sdp_offer'],
        ice_servers: agent_offer['ice_servers']
      }
    }
    ActionCable.server.broadcast("account_#{inbox.account_id}", payload)
    mark_agent_offer_generated(call)
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to finalize outbound server-relay: #{e.message}"
  end

  def status_timestamp(status_payload)
    return if status_payload[:timestamp].blank?

    Time.zone.at(status_payload[:timestamp].to_i)
  end

  def default_ice_servers
    [{ urls: ['stun:stun.l.google.com:19302'] }]
  end

  def fix_sdp_setup(sdp)
    sdp.present? ? sdp.gsub('a=setup:actpass', 'a=setup:active') : sdp
  end
end
