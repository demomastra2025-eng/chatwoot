class Api::V1::Accounts::ConferenceController < Api::V1::Accounts::BaseController
  before_action :set_voice_inbox_for_conference

  def token
    if twilio_conference_inbox?
      render json: Voice::Provider::Twilio::TokenService.new(
        inbox: @voice_inbox,
        user: Current.user,
        account: Current.account
      ).generate
    else
      render json: Telephony::WebphoneService.new(
        account: Current.account
      ).token_for(
        user: Current.user,
        inbox: @voice_inbox,
        client_instance_id: params[:client_instance_id]
      )
    end
  end

  def create
    conversation = fetch_conversation_by_display_id
    ensure_call_sid!(conversation)

    return render_unsupported_native_join_response(conversation) unless twilio_conference_inbox?

    conference_service = Voice::Provider::Twilio::ConferenceService.new(conversation: conversation)
    conference_sid = conference_service.ensure_conference_sid
    conference_service.mark_agent_joined(user: current_user)

    render json: {
      status: 'success',
      id: conversation.display_id,
      conference_sid: conference_sid,
      using_webrtc: true
    }
  end

  def destroy
    unless twilio_conference_inbox?
      return render json: { status: 'success', id: params[:conversation_id], provider: native_voice_provider,
                            join_supported: false }
    end

    conversation = fetch_conversation_by_display_id
    Voice::Provider::Twilio::ConferenceService.new(conversation: conversation).end_conference
    render json: { status: 'success', id: conversation.display_id }
  end

  private

  def ensure_call_sid!(conversation)
    return conversation.identifier if conversation.identifier.present?

    incoming_sid = params.require(:call_sid)

    conversation.update!(identifier: incoming_sid)
    incoming_sid
  end

  def set_voice_inbox_for_conference
    @voice_inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @voice_inbox, :show?
  end

  def twilio_conference_inbox?
    @voice_inbox.channel.is_a?(Channel::Voice) && @voice_inbox.channel.provider == 'twilio'
  end

  def fetch_conversation_by_display_id
    cid = params[:conversation_id]
    raise ActiveRecord::RecordNotFound, 'conversation_id required' if cid.blank?

    conversation = @voice_inbox.conversations.find_by!(display_id: cid)
    authorize conversation, :show?
    conversation
  end

  def native_voice_provider
    @voice_inbox.channel&.provider || 'janus_sip'
  end

  def render_unsupported_native_join_response(conversation)
    render json: {
      status: 'success',
      id: conversation.display_id,
      call_ref: conversation.identifier,
      provider: native_voice_provider,
      using_webrtc: false,
      join_supported: false
    }
  end
end
