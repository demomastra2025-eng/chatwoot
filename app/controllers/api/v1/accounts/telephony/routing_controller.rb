class Api::V1::Accounts::Telephony::RoutingController < Api::V1::Accounts::Telephony::BaseController
  before_action :check_admin_authorization?
  before_action :set_number_binding, only: [:update]

  def update
    result = routing_service.update_number_route!(number_binding: @number_binding, attributes: routing_params)

    render_payload(
      @number_binding.reload.to_telephony_h,
      meta: { bridge: result[:response] }
    )
  end

  def toggle_ai
    number_binding = find_number_binding_by_ref(ai_toggle_params[:number_ref])
    result = routing_service.toggle_ai!(
      number_binding: number_binding,
      enabled: parse_boolean(ai_toggle_params[:enabled]),
      ai_app_ref: ai_toggle_params[:ai_app_ref]
    )

    render_payload(
      number_binding.reload.to_telephony_h,
      meta: { bridge: result[:response] }
    )
  end

  private

  def set_number_binding
    @number_binding = find_number_binding_by_ref(params.require(:number_ref))
  end

  def find_number_binding_by_ref(number_ref)
    Current.account.telephony_number_bindings.find_by!(number_ref: number_ref)
  end

  def routing_service
    @routing_service ||= Telephony::RoutingService.new(account: Current.account)
  end

  def routing_params
    params.permit(
      :mode, :app_ref, :ai_app_ref, :ai_deployment_mode, :fonoster_ai_app_ref, :onelink_ai_app_ref,
      :fallback_ai_app_ref, :captain_assistant_id, :operator_agent_ref, :operator_agent_aor,
      :operator_distribution_mode, :fallback_mode, :fallback_message, ai_voice_settings: {}
    )
  end

  def ai_toggle_params
    params.permit(:number_ref, :enabled, :ai_app_ref)
  end
end
