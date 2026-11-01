class Api::V1::Accounts::TelegramPersonalCallsController < Api::V1::Accounts::BaseController
  GROUP_CHAT_TYPES = %w[group supergroup channel].freeze

  before_action :set_call, only: [:show, :accept, :reject, :terminate, :agent_answer, :reconnect, :dial]

  def show
    render json: TelegramPersonal::CallSerializer.show(@call, current_user)
  rescue TelegramPersonal::JanusMediaConfig::InvalidConfig => e
    render_janus_config_error(e)
  end

  def active
    call = current_account.calls.telegram_personal.active_for_agent(current_user.id).where(status: 'in_progress').last
    return render json: { call: nil } unless call

    render json: TelegramPersonal::CallSerializer.active(call)
  end

  def prepare_outbound
    conversation = current_account.conversations.find_by!(display_id: params[:conversation_id])
    authorize conversation, :show?
    error = validate_telegram_personal_calling(conversation)
    return render json: { error: error }, status: :unprocessable_entity if error

    call = with_operator_call_lock { outbound_service.prepare!(conversation) }
    render json: TelegramPersonal::CallSerializer.outbound_initiate(call, current_user)
  rescue Telephony::Error => e
    render_operator_busy(e)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Conversation not found' }, status: :not_found
  rescue TelegramPersonal::JanusMediaConfig::InvalidConfig => e
    render_janus_config_error(e)
  rescue StandardError => e
    Rails.logger.error "[TELEGRAM CALL] prepare_outbound failed: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def dial
    unless outbound_service.prepared_for_user?(@call)
      return render json: { error: 'Call is not an outbound prepared call' }, status: :unprocessable_entity
    end

    provider_call_id = outbound_service.dial!(@call)
    render json: TelegramPersonal::CallSerializer.dial(@call, provider_call_id)
  rescue TelegramPersonal::JanusMediaConfig::InvalidConfig => e
    render_janus_config_error(e)
  rescue StandardError => e
    Rails.logger.error "[TELEGRAM CALL] dial failed: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def accept
    with_operator_call_lock(excluding_whatsapp_call: @call) do
      service = TelegramPersonal::CallService.new(call: @call, agent: current_user)
      call = service.accept
      render json: TelegramPersonal::CallSerializer.media_server_accept(call, service.agent_offer, current_user)
    end
  rescue Telephony::Error => e
    render_operator_busy(e)
  rescue TelegramPersonal::CallErrors::NotRinging, TelegramPersonal::CallErrors::AlreadyAccepted => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue TelegramPersonal::JanusMediaConfig::InvalidConfig => e
    render_janus_config_error(e)
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    return render_media_leg_closed if e.media_leg_closed?

    Rails.logger.error "[TELEGRAM CALL] accept failed: #{e.message}"
    render json: { error: 'Failed to accept call' }, status: :internal_server_error
  rescue StandardError => e
    Rails.logger.error "[TELEGRAM CALL] accept failed: #{e.message}"
    render json: { error: 'Failed to accept call' }, status: :internal_server_error
  end

  def agent_answer
    return render_call_taken_by_another_agent unless call_owned_by_current_user?

    render_janus_config_error(TelegramPersonal::JanusMediaConfig::InvalidConfig.new('Telegram calls require Janus media'))
  end

  def reconnect
    error = reconnect_validation_error
    return render json: { error: error }, status: :unprocessable_entity if error
    return render_call_taken_by_another_agent unless call_owned_by_current_user?

    TelegramPersonal::ReconnectCallService.new(call: @call, agent: current_user).perform
    render json: TelegramPersonal::JanusMediaConfig.browser_payload(call: @call, user: current_user)
  rescue TelegramPersonal::CallErrors::NotCallOwner
    render_call_taken_by_another_agent
  rescue TelegramPersonal::CallErrors::NotInProgress
    render json: { error: 'Call is not in progress' }, status: :unprocessable_entity
  rescue TelegramPersonal::JanusMediaConfig::InvalidConfig => e
    render_janus_config_error(e)
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    return render_media_leg_closed if e.media_leg_closed?

    Rails.logger.error "[TELEGRAM CALL] reconnect failed: #{e.message}"
    render json: { error: 'Failed to reconnect' }, status: :internal_server_error
  end

  def reject
    return render_call_taken_by_another_agent if call_taken_by_another_agent?

    call = TelegramPersonal::CallService.new(call: @call, agent: current_user).reject
    render json: { id: call.id, status: call.status }
  rescue TelegramPersonal::CallErrors::NotCallOwner
    render_call_taken_by_another_agent
  rescue StandardError => e
    Rails.logger.error "[TELEGRAM CALL] reject failed: #{e.message}"
    render json: { error: 'Failed to reject call' }, status: :internal_server_error
  end

  def terminate
    return render_call_taken_by_another_agent if call_taken_by_another_agent?

    call = TelegramPersonal::CallService.new(call: @call, agent: current_user).terminate
    render json: { id: call.id, status: call.status }
  rescue TelegramPersonal::CallErrors::NotCallOwner
    render_call_taken_by_another_agent
  rescue StandardError => e
    Rails.logger.error "[TELEGRAM CALL] terminate failed: #{e.message}"
    render json: { error: 'Failed to terminate call' }, status: :internal_server_error
  end

  private

  def set_call
    @call = current_account.calls.telegram_personal.find(params[:id])
    authorize @call.conversation, :show?
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Call not found' }, status: :not_found
  end

  def outbound_service
    @outbound_service ||= TelegramPersonal::OutboundCallService.new(account: current_account, user: current_user)
  end

  def with_operator_call_lock(excluding_whatsapp_call: nil, &)
    Telephony::OperatorBusyService.new(
      account: current_account, user: current_user, excluding_whatsapp_call: excluding_whatsapp_call
    ).with_lock(&)
  end

  def reconnect_validation_error
    return 'No media session' if @call.media_session_id.blank?
    return 'Call is not in progress' unless @call.in_progress?

    nil
  end

  def validate_telegram_personal_calling(conversation)
    channel = conversation.inbox.channel
    return 'Calling is only supported on Telegram Personal inboxes' unless channel.is_a?(Channel::TelegramPersonal)
    return 'Calling is not enabled for this inbox' unless channel.voice_enabled?
    return 'Telegram Personal channel is not connected' unless channel.connection_state == 'connected'
    return 'Telegram voice calls are only supported in private chats' if group_conversation?(conversation)
    return 'Telegram gateway is not configured' unless Call.media_server_enabled?(inbox: conversation.inbox)

    nil
  end

  def group_conversation?(conversation)
    chat_type = conversation.additional_attributes&.dig('chat_type').to_s
    GROUP_CHAT_TYPES.include?(chat_type) || conversation.contact_inbox&.source_id.to_s.start_with?('-')
  end

  def call_owned_by_current_user?
    @call.accepted_by_agent_id.present? && @call.accepted_by_agent_id == current_user.id
  end

  def call_taken_by_another_agent?
    @call.accepted_by_agent_id.present? && @call.accepted_by_agent_id != current_user.id
  end

  def render_call_taken_by_another_agent
    render json: { error: 'Call accepted by another agent' }, status: :forbidden
  end

  def render_operator_busy(error)
    render json: { error: error.message, code: error.code, details: error.details }, status: error.status
  end

  def render_janus_config_error(error)
    render json: { error: error.message, code: 'janus_media_required' }, status: :unprocessable_entity
  end

  def render_media_leg_closed
    finalize_closed_media_leg_call
    render json: {
      error: 'media_leg_closed', code: 'media_leg_closed',
      status: 'media_leg_closed', message: 'Call media leg already closed'
    }, status: :conflict
  end

  def finalize_closed_media_leg_call
    return if @call.blank? || @call.terminal?

    TelegramPersonal::CallService.new(call: @call, agent: current_user).terminate
  rescue StandardError => e
    Rails.logger.warn "[TELEGRAM CALL] Failed to finalize media_leg_closed call #{@call&.id}: #{e.message}"
  end
end
