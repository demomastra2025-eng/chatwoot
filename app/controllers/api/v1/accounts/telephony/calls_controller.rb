class Api::V1::Accounts::Telephony::CallsController < Api::V1::Accounts::Telephony::BaseController
  before_action :set_call_session, only: [:show]

  def index
    sessions = Current.account.telephony_call_sessions.includes(:contact, :conversation, :inbox, :number_binding, :agent_binding).recent
    sessions = sessions.where(inbox_id: params[:inbox_id]) if params[:inbox_id].present?
    sessions = sessions.where(status: params[:status]) if params[:status].present?
    sessions = sessions.where(direction: params[:direction]) if params[:direction].present?
    sessions = sessions.limit(limit_param)

    render_payload(
      sessions.map(&:to_telephony_h),
      meta: { count: sessions.size }
    )
  end

  def show
    payload = @call_session.to_telephony_h
    payload[:bridge] = calls_service.find_remote(@call_session.external_call_ref) if parse_boolean(params[:include_bridge], default: false)
    render_payload(payload)
  end

  def outbound
    contact = Current.account.contacts.find(params.require(:contact_id))
    inbox = Current.user.assigned_inboxes.where(account_id: Current.account.id, channel_type: 'Channel::Voice').find(params.require(:inbox_id))

    authorize contact, :show?
    authorize inbox, :show?

    result = Voice::OutboundCallBuilder.perform!(
      account: Current.account,
      inbox: inbox,
      user: Current.user,
      contact: contact
    )

    render json: {
      conversation_id: result[:conversation].display_id,
      inbox_id: inbox.id,
      call_sid: result[:call_sid],
      conference_sid: result[:conversation].additional_attributes['conference_sid'],
      call_session: result[:call_session]&.to_telephony_h
    }, status: :created
  end

  private

  def set_call_session
    @call_session = Current.account.telephony_call_sessions.find_by!(external_call_ref: params[:call_ref])
  end

  def calls_service
    @calls_service ||= Telephony::CallsService.new(account: Current.account)
  end

  def limit_param
    value = params[:limit].to_i
    return 50 if value <= 0

    [value, 100].min
  end
end
