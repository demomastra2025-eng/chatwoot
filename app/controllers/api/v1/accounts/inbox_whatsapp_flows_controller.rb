class Api::V1::Accounts::InboxWhatsappFlowsController < Api::V1::Accounts::BaseController
  before_action :fetch_inbox
  before_action :validate_whatsapp_cloud_channel
  before_action :fetch_flow, only: %i[update destroy sessions]

  def index
    flows = @inbox.whatsapp_flows.latest_first
    render json: { payload: flows.map { |flow| flow_payload(flow) } }
  end

  def create
    flow = @inbox.whatsapp_flows.new(flow_params.merge(account: Current.account))
    if flow.save
      render json: flow_payload(flow), status: :created
    else
      render json: { error: flow.errors.full_messages.to_sentence }, status: :unprocessable_content
    end
  rescue ActionController::ParameterMissing
    render json: { error: 'Flow parameters are required' }, status: :unprocessable_content
  end

  def update
    if @flow.update(flow_params)
      render json: flow_payload(@flow)
    else
      render json: { error: @flow.errors.full_messages.to_sentence }, status: :unprocessable_content
    end
  end

  def destroy
    @flow.destroy!
    head :no_content
  end

  def sessions
    session = @flow.flow_sessions.create!(session_attributes)
    render json: flow_session_payload(session), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_content
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @inbox, :whatsapp_flows?
  end

  def fetch_flow
    @flow = @inbox.whatsapp_flows.find(params[:id])
  end

  def validate_whatsapp_cloud_channel
    return if @inbox.whatsapp? && @inbox.channel.provider == 'whatsapp_cloud'

    render json: { error: 'WhatsApp Flow management is only available for WhatsApp Cloud channels' }, status: :bad_request
  end

  def flow_params
    params.require(:flow).permit(
      :provider_flow_id,
      :name,
      :title,
      :status,
      :category,
      :mode,
      flow_json: {},
      metadata: {}
    )
  end

  def session_attributes
    permitted = session_params
    {
      account: Current.account,
      inbox: @inbox,
      conversation: find_conversation(permitted[:conversation_id]),
      message: find_message(permitted[:message_id]),
      expires_at: permitted[:expires_at],
      request_payload: permitted[:request_payload].to_h,
      metadata: permitted[:metadata].to_h
    }.compact
  end

  def session_params
    return ActionController::Parameters.new.permit if params[:session].blank?

    params.require(:session).permit(:conversation_id, :message_id, :expires_at, request_payload: {}, metadata: {})
  end

  def find_conversation(value)
    return if value.blank?

    Current.account.conversations.find_by(id: value) || Current.account.conversations.find_by!(display_id: value)
  end

  def find_message(value)
    return if value.blank?

    Current.account.messages.find(value)
  end

  def flow_payload(flow)
    {
      id: flow.id,
      inbox_id: flow.inbox_id,
      provider_flow_id: flow.provider_flow_id,
      name: flow.name,
      title: flow.title,
      display_title: flow.display_title,
      status: flow.status,
      category: flow.category,
      mode: flow.mode,
      flow_json: flow.flow_json,
      metadata: flow.metadata,
      last_synced_at: flow.last_synced_at&.iso8601,
      created_at: flow.created_at.iso8601,
      updated_at: flow.updated_at.iso8601
    }
  end

  def flow_session_payload(session)
    {
      id: session.id,
      whatsapp_flow_id: session.whatsapp_flow_id,
      inbox_id: session.inbox_id,
      conversation_id: session.conversation_id,
      message_id: session.message_id,
      response_message_id: session.response_message_id,
      status: session.status,
      expires_at: session.expires_at&.iso8601,
      sent_at: session.sent_at&.iso8601,
      submitted_at: session.submitted_at&.iso8601,
      token_prefix: session.token_prefix,
      metadata: session.metadata,
      created_at: session.created_at.iso8601,
      updated_at: session.updated_at.iso8601
    }
  end
end
