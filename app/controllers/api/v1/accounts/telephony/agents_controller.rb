class Api::V1::Accounts::Telephony::AgentsController < Api::V1::Accounts::Telephony::BaseController
  before_action :set_agent_binding, only: [:enabled]

  def index
    check_admin_authorization?

    render_payload(
      Current.account.telephony_agent_bindings.includes(:user).recent.map(&:to_telephony_h),
      meta: { count: Current.account.telephony_agent_bindings.count }
    )
  end

  def enabled
    authorize_enabled_change!

    response = agents_service.set_enabled!(
      binding: @agent_binding,
      enabled: parse_boolean(params.require(:enabled))
    )

    render_payload(@agent_binding.reload.to_telephony_h, meta: { janus_sip: response })
  end

  private

  def set_agent_binding
    @agent_binding = Current.account.telephony_agent_bindings.find_by!(agent_ref: params.require(:agent_ref))
  end

  def authorize_enabled_change!
    return if Current.account_user.administrator?
    return if @agent_binding.user_id == Current.user.id

    raise Pundit::NotAuthorizedError
  end

  def agents_service
    @agents_service ||= Telephony::AgentsService.new(account: Current.account)
  end
end
