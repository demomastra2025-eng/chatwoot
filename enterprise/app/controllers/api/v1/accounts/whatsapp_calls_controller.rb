class Api::V1::Accounts::WhatsappCallsController < Api::V1::Accounts::BaseController
  PERMISSION_REQUEST_THROTTLE = 5.minutes
  ALLOWED_PEER_ROLES = %w[listen_only participant].freeze
  ALLOWED_AUDIO_MODES = %w[replace mix].freeze
  ALLOWED_AUDIO_EXTENSIONS = %w[.ogg].freeze
  ALLOWED_CLIENT_TIMING_STAGE_KEYS = %w[
    offer_received_ms get_user_media_start_ms get_user_media_ok_ms
    set_remote_description_ok_ms create_answer_ok_ms set_local_description_ok_ms
    fast_ice_ready_ms agent_answer_post_start_ms agent_answer_error_ms
  ].freeze
  SAFE_AUDIO_PATH_PATTERN = %r{\A[a-zA-Z0-9][a-zA-Z0-9_\.\-/]*\z}

  before_action :ensure_whatsapp_call_enabled
  before_action :set_call, only: [:show, :accept, :reject, :terminate, :upload_recording, :agent_answer, :reconnect, :join, :play_audio, :dial]

  def show
    render json: {
      id: @call.id,
      call_id: @call.provider_call_id,
      status: @call.status,
      direction: @call.direction_label,
      conversation_id: @call.conversation_id,
      conversation_display_id: @call.conversation&.display_id,
      communication_thread_id: communication_thread_display_id(@call),
      communicationThreadId: communication_thread_display_id(@call),
      inbox_id: @call.inbox_id,
      message_id: @call.message_id,
      media_session_id: @call.media_session_id,
      # In server-relay mode the browser must not talk WebRTC to Meta directly
      # — the media server owns that peer connection. Omitting sdp_offer forces
      # the FE's isServerRelayCall() check to return true so the accept flow
      # waits for the whatsapp_call.agent_offer broadcast from Rails instead of
      # negotiating straight with Meta.
      sdp_offer: @call.ringing? && !@call.media_server_enabled? ? @call.sdp_offer : nil,
      ice_servers: @call.media_server_enabled? ? [] : @call.ice_servers,
      media_server_enabled: @call.media_server_enabled?,
      caller: caller_info,
      agent_offer: @call.ringing? && @call.media_server_enabled? ? agent_offer_for_current_user(@call) : nil
    }
  end

  def accept
    sdp_answer = params[:sdp_answer]
    if !@call.media_server_enabled? && sdp_answer.blank?
      return render json: { error: 'sdp_answer is required' }, status: :unprocessable_entity
    end

    with_operator_call_lock(excluding_whatsapp_call: @call) do
      if @call.media_server_enabled?
        service = Whatsapp::CallService.new(call: @call, agent: current_user)
        call = service.accept
        render json: media_server_accept_payload(call, service.agent_offer)
      else
        call = Whatsapp::CallService.new(call: @call, agent: current_user).pre_accept_and_accept(sdp_answer)
        render json: { id: call.id, status: call.status, message_id: call.message_id, conversation_id: call.conversation_id,
                       conversation_display_id: call.conversation&.display_id }
      end
    end
  rescue Telephony::Error => e
    render_operator_busy(e)
  rescue Whatsapp::CallErrors::NotRinging, Whatsapp::CallErrors::AlreadyAccepted => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Whatsapp::MediaServerClient::SessionError => e
    if e.media_leg_closed?
      Rails.logger.warn "[WHATSAPP CALL] accept media leg closed: call_id=#{@call.id} code=#{e.error_code} status=#{e.http_status}"
      render_media_leg_closed
    else
      Rails.logger.error "[WHATSAPP CALL] accept failed: #{e.message}"
      render json: { error: 'Failed to accept call' }, status: :internal_server_error
    end
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] accept failed: #{e.message}"
    render json: { error: 'Failed to accept call' }, status: :internal_server_error
  end

  def reject
    call = Whatsapp::CallService.new(call: @call, agent: current_user).reject
    render json: { id: call.id, status: call.status }
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] reject failed: #{e.message}"
    render json: { error: 'Failed to reject call' }, status: :internal_server_error
  end

  def terminate
    call = Whatsapp::CallService.new(call: @call, agent: current_user).terminate
    render json: { id: call.id, status: call.status }
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] terminate failed: #{e.message}"
    render json: { error: 'Failed to terminate call' }, status: :internal_server_error
  end

  def upload_recording
    return render json: { error: 'No recording file provided' }, status: :unprocessable_entity if params[:recording].blank?
    return render json: { error: 'Call is not ended' }, status: :unprocessable_entity unless @call.terminal?

    attach_recording_and_enqueue_transcription
    render json: { id: @call.id, status: 'uploaded' }
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] upload_recording failed: #{e.message}"
    render json: { error: 'Failed to upload recording' }, status: :internal_server_error
  end

  def active
    call = current_account.calls.whatsapp.active_for_agent(current_user.id).last
    if call
      elapsed = call.started_at ? (Time.current - call.started_at).to_i : 0
      render json: {
        id: call.id,
        call_id: call.provider_call_id,
        direction: call.direction_label,
        conversation_id: call.conversation_id,
        conversation_display_id: call.conversation&.display_id,
        communication_thread_id: communication_thread_display_id(call),
        communicationThreadId: communication_thread_display_id(call),
        inbox_id: call.inbox_id,
        status: call.status,
        elapsed_seconds: elapsed,
        media_session_id: call.media_session_id,
        media_server_enabled: call.media_server_enabled?,
        caller: caller_info_for(call)
      }
    else
      render json: { call: nil }
    end
  end

  def agent_answer
    return render json: { error: 'sdp_answer is required' }, status: :unprocessable_entity if params[:sdp_answer].blank?
    return render json: { error: 'No media session' }, status: :unprocessable_entity if @call.media_session_id.blank?

    client = Whatsapp::MediaServerClient.new
    log_agent_answer_client_timing('received')
    peer_id = verified_agent_peer_id
    return if peer_id == false

    if peer_id.present?
      client.set_agent_answer(@call.media_session_id, sdp_answer: params[:sdp_answer], peer_id: peer_id)
    else
      client.set_agent_answer(@call.media_session_id, sdp_answer: params[:sdp_answer])
    end
    log_agent_answer_client_timing('ok')
    render json: { success: true }
  rescue Whatsapp::MediaServerClient::SessionError => e
    handle_agent_answer_session_error(e)
  rescue Whatsapp::MediaServerClient::ConnectionError => e
    handle_agent_answer_connection_error(e)
  end

  def reconnect
    return render json: { error: 'No media session' }, status: :unprocessable_entity if @call.media_session_id.blank?
    return render json: { error: 'Call is not in progress' }, status: :unprocessable_entity unless @call.in_progress?

    client = Whatsapp::MediaServerClient.new
    response = client.reconnect_agent(@call.media_session_id)
    render json: {
      sdp_offer: response['sdp_offer'],
      ice_servers: response['ice_servers']
    }
  rescue Whatsapp::MediaServerClient::SessionError, Whatsapp::MediaServerClient::ConnectionError => e
    Rails.logger.error "[WHATSAPP CALL] reconnect failed: #{e.message}"
    render json: { error: 'Failed to reconnect' }, status: :internal_server_error
  end

  def join
    return render json: { error: 'No media session' }, status: :unprocessable_entity if @call.media_session_id.blank?

    role = params[:role] || 'listen_only'
    return render json: { error: 'Invalid role' }, status: :unprocessable_entity unless ALLOWED_PEER_ROLES.include?(role)

    client = Whatsapp::MediaServerClient.new
    response = client.add_peer(@call.media_session_id, role: role, label: current_user.name)
    render json: {
      peer_id: response['peer_id'],
      sdp_offer: response['sdp_offer'],
      ice_servers: response['ice_servers']
    }
  rescue Whatsapp::MediaServerClient::SessionError, Whatsapp::MediaServerClient::ConnectionError => e
    Rails.logger.error "[WHATSAPP CALL] join failed: #{e.message}"
    render json: { error: 'Failed to join call' }, status: :internal_server_error
  end

  def play_audio
    return render json: { error: 'No media session' }, status: :unprocessable_entity if @call.media_session_id.blank?

    file_path = sanitized_audio_file_path
    return render json: { error: 'file_path is required' }, status: :unprocessable_entity if params[:file_path].blank?
    return render json: { error: 'Invalid file_path' }, status: :unprocessable_entity if file_path.blank?

    mode = params[:mode] || 'replace'
    return render json: { error: 'Invalid mode' }, status: :unprocessable_entity unless ALLOWED_AUDIO_MODES.include?(mode)

    client = Whatsapp::MediaServerClient.new
    response = client.inject_audio(
      @call.media_session_id,
      file_path: file_path,
      mode: mode,
      loop: ActiveModel::Type::Boolean.new.cast(params[:loop])
    )
    render json: { injection_id: response['injection_id'] || response['id'] }
  rescue Whatsapp::MediaServerClient::SessionError, Whatsapp::MediaServerClient::ConnectionError => e
    Rails.logger.error "[WHATSAPP CALL] play_audio failed: #{e.message}"
    render json: { error: 'Failed to play audio' }, status: :internal_server_error
  end

  def initiate
    conversation = current_account.conversations.find_by!(display_id: params[:conversation_id])
    authorize conversation, :show?
    error = validate_whatsapp_calling(conversation)
    return render json: { error: error }, status: :unprocessable_entity if error

    call = with_operator_call_lock { create_outbound_call(conversation) }
    message = Whatsapp::CallMessageBuilder.create!(conversation: conversation, call: call, user: current_user)
    call.update!(message_id: message.id)
    render json: outbound_initiate_payload(call, message)
  rescue Whatsapp::CallErrors::NoCallPermission
    handle_no_call_permission(conversation)
  rescue Telephony::Error => e
    render_operator_busy(e)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Conversation not found' }, status: :not_found
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] initiate failed: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def prepare_outbound
    conversation = current_account.conversations.find_by!(display_id: params[:conversation_id])
    authorize conversation, :show?
    error = validate_whatsapp_calling(conversation)
    return render json: { error: error }, status: :unprocessable_entity if error
    unless media_server_enabled_for_inbox?(conversation.inbox)
      return render json: { error: 'Media server is required for prepared outbound calls' }, status: :unprocessable_entity
    end

    call = with_operator_call_lock { prepare_outbound_call_via_media_server(conversation) }
    message = Whatsapp::CallMessageBuilder.create!(conversation: conversation, call: call, user: current_user)
    call.update!(message_id: message.id)
    schedule_call_cleanup(call)
    render json: outbound_initiate_payload(call, message)
  rescue Telephony::Error => e
    render_operator_busy(e)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Conversation not found' }, status: :not_found
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] prepare_outbound failed: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def dial
    return render json: { error: 'Call is not an outbound prepared call' }, status: :unprocessable_entity unless prepared_outbound_call?(@call)

    provider_call_id = dial_prepared_outbound_call(@call)
    render json: {
      id: @call.id,
      status: @call.status,
      call_id: provider_call_id,
      message_id: @call.message_id,
      media_session_id: @call.media_session_id
    }
  rescue Whatsapp::CallErrors::NoCallPermission
    handle_no_call_permission(@call.conversation)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] dial failed: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def with_operator_call_lock(excluding_whatsapp_call: nil, &block)
    Telephony::OperatorBusyService.new(
      account: current_account,
      user: current_user,
      excluding_whatsapp_call: excluding_whatsapp_call
    ).with_lock(&block)
  end

  def render_operator_busy(error)
    render json: { error: error.message, code: error.code, details: error.details }, status: error.status
  end

  def outbound_initiate_payload(call, message)
    payload = {
      status: 'calling',
      call_id: call.provider_call_id,
      id: call.id,
      message_id: message.id,
      media_session_id: call.media_session_id
    }.compact
    agent_offer = @outbound_agent_offer || call.meta&.dig('agent_offer')
    payload[:agent_offer] = normalize_agent_offer(agent_offer) if agent_offer.present?
    payload
  end

  def media_server_accept_payload(call, agent_offer)
    {
      id: call.id,
      status: call.status,
      message_id: call.message_id,
      media_session_id: call.media_session_id,
      conversation_id: call.conversation_id,
      conversation_display_id: call.conversation&.display_id,
      communication_thread_id: communication_thread_display_id(call),
      communicationThreadId: communication_thread_display_id(call),
      agent_offer: normalize_agent_offer(agent_offer)
    }.compact
  end

  def communication_thread_display_id(call)
    conversation = call.conversation
    return if conversation.blank?

    (conversation.communication_thread || conversation.refresh_communication_thread!)&.display_id
  end

  def agent_offer_for_current_user(call)
    meta = call.meta || {}
    offer = meta.dig('agent_offers', current_user.id.to_s)
    offer ||= meta['agent_offer']
    normalize_agent_offer(offer)
  end

  def normalize_agent_offer(offer)
    return if offer.blank?

    offer.to_h.stringify_keys.slice('peer_id', 'sdp_offer', 'ice_servers')
  end

  def verified_agent_peer_id
    meta = @call.meta || {}
    agent_offers = meta['agent_offers'] || {}
    expected_peer_id = agent_offers.dig(current_user.id.to_s, 'peer_id')
    requested_peer_id = params[:peer_id].presence

    unless @call.accepted_by_agent_id.blank? || @call.accepted_by_agent_id == current_user.id
      render json: { error: 'Call accepted by another agent' }, status: :forbidden
      return false
    end

    if agent_offers.blank?
      single_offer_peer_id = meta.dig('agent_offer', 'peer_id')
      if single_offer_peer_id.present?
        if requested_peer_id.present? && requested_peer_id != single_offer_peer_id
          render json: { error: 'peer_id does not belong to current agent' }, status: :forbidden
          return false
        end

        return requested_peer_id || single_offer_peer_id
      end

      return requested_peer_id if requested_peer_id.present?

      return
    end

    if expected_peer_id.blank?
      render json: { error: 'No prepared peer for current agent' }, status: :forbidden
      return false
    end

    if requested_peer_id.present? && requested_peer_id != expected_peer_id
      render json: { error: 'peer_id does not belong to current agent' }, status: :forbidden
      return false
    end

    expected_peer_id
  end

  def render_media_leg_closed
    render json: {
      error: 'media_leg_closed',
      code: 'media_leg_closed',
      status: 'media_leg_closed',
      message: 'Call media leg already closed'
    }, status: :conflict
  end

  def handle_agent_answer_session_error(error)
    log_agent_answer_client_timing('error')
    return handle_agent_answer_media_leg_closed(error) if error.media_leg_closed?

    handle_agent_answer_connection_error(error, log_timing: false)
  end

  def handle_agent_answer_media_leg_closed(error)
    Rails.logger.warn(
      "[WHATSAPP CALL] agent_answer media leg closed: call_id=#{@call.id} " \
      "media_session_id=#{@call.media_session_id} code=#{error.error_code} status=#{error.http_status}"
    )
    render_media_leg_closed
  end

  def handle_agent_answer_connection_error(error, log_timing: true)
    log_agent_answer_client_timing('error') if log_timing
    Rails.logger.error "[WHATSAPP CALL] agent_answer failed: #{error.message}"
    render json: { error: 'Failed to set agent answer' }, status: :internal_server_error
  end

  def log_agent_answer_client_timing(result)
    timing = sanitized_client_timing_payload
    return if timing.blank?

    Rails.logger.info(
      "[WHATSAPP CALL] agent_answer client_timing call_id=#{@call.id} " \
      "media_session_id=#{@call.media_session_id} result=#{result} " \
      "direction=#{timing[:direction]} context=#{timing[:context]} #{timing[:stages]}".strip
    )
  end

  def sanitized_client_timing_payload
    timing = normalized_timing_hash(params[:client_timing])
    return if timing.blank?

    {
      direction: sanitized_timing_value(timing['direction'] || timing[:direction]),
      context: sanitized_timing_value(timing['context'] || timing[:context]),
      stages: sanitized_client_timing_stages(normalized_timing_hash(timing['stages'] || timing[:stages]))
    }
  end

  def normalized_timing_hash(value)
    return {} if value.blank?

    value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
  end

  def sanitized_client_timing_stages(stages)
    ALLOWED_CLIENT_TIMING_STAGE_KEYS.filter_map do |key|
      value = stages[key] || stages[key.to_sym]
      next if value.blank? || value.to_s !~ /\A\d+\z/

      "#{key}=#{value.to_i}"
    end.join(' ')
  end

  def sanitized_timing_value(value)
    value.to_s.gsub(/[^a-zA-Z0-9_.:-]/, '_').first(64)
  end

  def create_outbound_call(conversation)
    contact_phone = conversation.contact&.phone_number
    raise ArgumentError, 'Contact phone number not available' if contact_phone.blank?
    raise ArgumentError, 'sdp_offer is required' if params[:sdp_offer].blank? && !media_server_enabled_for_inbox?(conversation.inbox)

    if media_server_enabled_for_inbox?(conversation.inbox)
      create_outbound_call_via_media_server(conversation, contact_phone)
    else
      create_outbound_call_direct(conversation, contact_phone)
    end
  end

  def prepare_outbound_call_via_media_server(conversation)
    contact_phone = conversation.contact&.phone_number
    raise ArgumentError, 'Contact phone number not available' if contact_phone.blank?

    client = Whatsapp::MediaServerClient.new
    session_id = nil
    session_response = client.create_session(
      call_id: "pending_#{SecureRandom.hex(8)}",
      direction: 'outgoing',
      sdp_offer: nil,
      ice_servers: [{ urls: ['stun:stun.l.google.com:19302'] }],
      account_id: current_account.id
    )
    session_id = session_response['session_id']
    sdp_offer = session_response['meta_sdp_offer']
    agent_offer = client.generate_agent_offer(session_id)
    pending_provider_call_id = "pending_outbound_#{SecureRandom.hex(12)}"

    current_account.calls.create!(
      provider: :whatsapp,
      inbox: conversation.inbox, conversation: conversation, contact: conversation.contact,
      provider_call_id: pending_provider_call_id, direction: :outgoing, status: 'ringing',
      accepted_by_agent_id: current_user.id,
      media_session_id: session_id,
      meta: {
        'sdp_offer' => sdp_offer,
        'outbound_prepare_pending' => true,
        'outbound_prepared_at' => Time.zone.now.to_i,
        'agent_offer_generated_at' => Time.zone.now.to_i,
        'agent_offer' => normalize_agent_offer(agent_offer)
      }
    )
  rescue StandardError
    terminate_orphan_media_session(client, session_id)
    raise
  end

  def prepared_outbound_call?(call)
    call.outgoing? &&
      call.media_server_enabled? &&
      call.media_session_id.present? &&
      call.meta&.dig('outbound_prepare_pending') == true &&
      call.meta&.dig('outbound_dialing') != true &&
      call.accepted_by_agent_id == current_user.id
  end

  def claim_prepared_outbound_dial!(call)
    call.with_lock do
      call.reload
      raise ArgumentError, 'Call is not an outbound prepared call' unless prepared_outbound_call?(call)

      call.update!(meta: (call.meta || {}).merge('outbound_dialing' => true))
    end
  end

  def dial_prepared_outbound_call(call)
    claim_prepared_outbound_dial!(call)

    contact_phone = call.conversation.contact&.phone_number
    raise ArgumentError, 'Contact phone number not available' if contact_phone.blank?

    sdp_offer = call.meta&.dig('sdp_offer')
    raise ArgumentError, 'Prepared media SDP offer is missing' if sdp_offer.blank?

    provider_service = call.inbox.channel.provider_service
    provider_call_id = nil
    result = provider_service.initiate_call(contact_phone.delete('+'), sdp_offer)
    provider_call_id = extract_provider_call_id(result)
    raise ArgumentError, 'Provider call id not returned' if provider_call_id.blank?

    update_prepared_outbound_provider_ref!(call, provider_call_id)
    schedule_call_cleanup(call)
    replay_cached_outbound_connect(call)
    provider_call_id
  rescue StandardError
    terminate_provider_call(provider_service, provider_call_id)
    mark_prepared_outbound_failed(call) if call&.persisted?
    raise
  end

  def update_prepared_outbound_provider_ref!(call, provider_call_id)
    call.with_lock do
      call.reload
      meta = (call.meta || {}).merge(
        'outbound_prepare_pending' => false,
        'outbound_dialing' => false,
        'outbound_dialed_at' => Time.zone.now.to_i
      )
      call.update!(provider_call_id: provider_call_id, meta: meta)
    end

    update_outbound_call_message_provider_ref!(call, provider_call_id)
  end

  def update_outbound_call_message_provider_ref!(call, provider_call_id)
    message = call.message
    return unless message

    attrs = (message.content_attributes || {}).dup
    attrs['data'] ||= {}
    attrs['data']['call_sid'] = provider_call_id
    message.update!(source_id: provider_call_id, content_attributes: attrs)
  end

  def mark_prepared_outbound_failed(call)
    call.with_lock do
      call.reload
      failed_meta = (call.meta || {}).merge(
        'outbound_prepare_pending' => false,
        'outbound_dialing' => false
      )
      call.update!(status: 'failed', meta: failed_meta) unless call.terminal?
    end
    Whatsapp::CallMessageBuilder.update_status!(call: call.reload, status: 'failed')
    terminate_orphan_media_session(Whatsapp::MediaServerClient.new, call.media_session_id)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to mark prepared outbound failed #{call&.id}: #{e.message}"
  end

  def create_outbound_call_direct(conversation, contact_phone)
    result = conversation.inbox.channel.provider_service.initiate_call(contact_phone.delete('+'), params[:sdp_offer])
    provider_call_id = extract_provider_call_id(result)
    raise ArgumentError, 'Provider call id not returned' if provider_call_id.blank?

    call = current_account.calls.create!(
      provider: :whatsapp,
      inbox: conversation.inbox, conversation: conversation, contact: conversation.contact,
      provider_call_id: provider_call_id, direction: :outgoing, status: 'ringing',
      accepted_by_agent_id: current_user.id,
      meta: { sdp_offer: params[:sdp_offer] }
    )
    schedule_call_cleanup(call)
    call
  end

  def create_outbound_call_via_media_server(conversation, contact_phone)
    client = Whatsapp::MediaServerClient.new
    session_id = nil
    provider_call_id = nil
    provider_service = conversation.inbox.channel.provider_service

    # Step 1: Create session on media server (generates SDP offer for Meta)
    session_response = client.create_session(
      call_id: "pending_#{SecureRandom.hex(8)}",
      direction: 'outgoing',
      sdp_offer: nil,
      ice_servers: [{ urls: ['stun:stun.l.google.com:19302'] }],
      account_id: current_account.id
    )
    session_id = session_response['session_id']

    # Step 2: Prepare the browser-agent leg before calling Meta. This avoids
    # adding an extra no-local-call-row window after Meta accepts /calls and
    # lets the browser start answering as soon as /initiate returns.
    @outbound_agent_offer = client.generate_agent_offer(session_id)

    # Step 3: Send the media server's SDP offer to Meta to initiate the call
    sdp_offer = session_response['meta_sdp_offer']
    result = provider_service.initiate_call(contact_phone.delete('+'), sdp_offer)
    provider_call_id = extract_provider_call_id(result)
    raise ArgumentError, 'Provider call id not returned' if provider_call_id.blank?

    call = current_account.calls.create!(
      provider: :whatsapp,
      inbox: conversation.inbox, conversation: conversation, contact: conversation.contact,
      provider_call_id: provider_call_id, direction: :outgoing, status: 'ringing',
      accepted_by_agent_id: current_user.id,
      media_session_id: session_id,
      meta: { sdp_offer: sdp_offer, agent_offer_generated_at: Time.zone.now.to_i }
    )
    schedule_call_cleanup(call)
    replay_cached_outbound_connect(call)
    call
  rescue StandardError
    terminate_provider_call(provider_service, provider_call_id)
    terminate_orphan_media_session(client, session_id)
    raise
  end

  def replay_cached_outbound_connect(call)
    cached_payload = Whatsapp::IncomingCallService.pop_cached_outbound_connect(
      account_id: current_account.id,
      provider_call_id: call.provider_call_id
    )
    return if cached_payload.blank?

    Whatsapp::IncomingCallService.new(inbox: call.inbox, params: { calls: [cached_payload] }).perform
  end

  def schedule_call_cleanup(call)
    Whatsapp::CallCleanupJob.set(wait: Whatsapp::IncomingCallService::RINGING_CLEANUP_DELAY).perform_later(call.id)
  end

  def terminate_provider_call(provider_service, provider_call_id)
    return if provider_call_id.blank?

    provider_service.terminate_call(provider_call_id)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to terminate orphan provider call #{provider_call_id}: #{e.message}"
  end

  def terminate_orphan_media_session(client, session_id)
    return if session_id.blank?

    client.terminate_session(session_id)
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to terminate orphan media session #{session_id}: #{e.message}"
  end

  def handle_no_call_permission(conversation)
    status = nil

    conversation.with_lock do
      if permission_request_throttled?(conversation)
        status = 'permission_pending'
        next
      end

      result = send_permission_request_safely(conversation)
      if result
        record_permission_request_wamid(conversation, result)
        emit_permission_requested_activity(conversation)
        status = 'permission_requested'
      else
        status = 'failed'
      end
    end

    return render json: { error: 'Failed to send call permission request' }, status: :unprocessable_entity if status == 'failed'

    render json: { status: status }, status: :unprocessable_entity
  end

  def send_permission_request_safely(conversation)
    contact_phone = conversation.contact.phone_number.delete('+')
    conversation.inbox.channel.provider_service.send_call_permission_request(contact_phone, *permission_request_body_args(conversation))
  rescue StandardError => e
    Rails.logger.warn "[WHATSAPP CALL] permission_request failed: #{e.class} #{e.message}"
    nil
  end

  def record_permission_request_wamid(conversation, result)
    attrs = (conversation.additional_attributes || {}).merge(
      'call_permission_requested_at' => Time.current.iso8601,
      'call_permission_request_message_id' => result.dig('messages', 0, 'id')
    )
    conversation.update!(additional_attributes: attrs)
  end

  def emit_permission_requested_activity(conversation)
    content = I18n.t(
      'conversations.activity.whatsapp_call.permission_requested',
      contact_name: conversation.contact.name,
      default: "#{conversation.contact.name} was sent a WhatsApp call permission request"
    )
    ::Conversations::ActivityMessageJob.perform_later(
      conversation,
      { account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity, content: content }
    )
  end

  def validate_whatsapp_calling(conversation)
    channel = conversation.inbox.channel
    return 'Calling is only supported on WhatsApp Cloud inboxes' unless channel.is_a?(Channel::Whatsapp)
    return 'Calling is not enabled for this inbox' unless channel.voice_enabled?

    nil
  end

  def extract_provider_call_id(result)
    return if result.blank?

    result.dig('calls', 0, 'id') || result.dig('messages', 0, 'id') || result['call_id']
  end

  def permission_request_throttled?(conversation)
    timestamp = conversation.additional_attributes&.dig('call_permission_requested_at')
    timestamp.present? && Time.zone.parse(timestamp) > PERMISSION_REQUEST_THROTTLE.ago
  rescue ArgumentError, TypeError
    false
  end

  def permission_request_body_args(conversation)
    custom_body = conversation.inbox.channel.provider_config&.dig('call_permission_request_body').presence
    custom_body ? [custom_body] : []
  end

  def ensure_whatsapp_call_enabled
    render_payment_required('WhatsApp calling is not enabled for this account') unless current_account.feature_enabled?('whatsapp_call')
  end

  def media_server_enabled_for_inbox?(inbox)
    Call.media_server_enabled?(inbox: inbox)
  end

  def set_call
    @call = current_account.calls.whatsapp.find(params[:id])
    authorize @call.conversation, :show?
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Call not found' }, status: :not_found
  end

  def attach_recording_and_enqueue_transcription
    @call.recording.attach(params[:recording])
    Whatsapp::CallMessageBuilder.update_recording_url!(call: @call)
    return unless @call.account.call_transcriptions_enabled?

    Whatsapp::CallTranscriptionJob.perform_later(@call.id)
  end

  def sanitized_audio_file_path
    raw_path = params[:file_path].to_s.strip
    return if raw_path.blank?
    return if raw_path.match?(/\A[a-z][a-z0-9+\-.]*:/i)
    return if raw_path.include?('\\') || raw_path.include?('\0')

    pathname = Pathname.new(raw_path)
    return if pathname.absolute?

    clean_path = pathname.cleanpath.to_s
    return if clean_path == '.' || clean_path == '..' || clean_path.start_with?('../')
    return unless clean_path.match?(SAFE_AUDIO_PATH_PATTERN)
    return unless ALLOWED_AUDIO_EXTENSIONS.include?(File.extname(clean_path).downcase)

    audio_root = audio_assets_root
    return if audio_root.blank?

    resolved_path = audio_root.join(clean_path).realpath
    return unless resolved_path.to_s.start_with?("#{audio_root}/")
    return unless resolved_path.file?

    clean_path
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def audio_assets_root
    configured_root = ENV['MEDIA_SERVER_AUDIO_ASSETS_ROOT'].presence
    Pathname.new(configured_root || Rails.root.join('enterprise/media-server/audio')).realpath
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def caller_info
    caller_info_for(@call)
  end

  def caller_info_for(call)
    contact = call.conversation&.contact
    return {} unless contact

    { name: contact.name, phone: contact.phone_number, avatar: contact.avatar_url }
  end
end
