class Api::V1::Accounts::Telephony::TelegramSoftphoneController < Api::V1::Accounts::Telephony::BaseController
  skip_before_action :ensure_voice_enabled!

  def show
    render_payload(current_or_unpersisted_binding_payload)
  end

  def link_token
    ensure_bot_configured!
    token_data = find_or_create_binding!.issue_link_token!
    render_payload(find_or_create_binding!.status_payload.merge(token_data))
  end

  def update
    on_line = parse_boolean(params.require(:on_line))
    binding = find_or_create_binding!
    on_line ? binding.go_on_line! : binding.go_off_line!
    render_payload(binding.status_payload)
  end

  def destroy
    binding = Current.account.telephony_telegram_operator_bindings.find_by(user_id: Current.user.id)
    binding&.disconnect!
    render_payload(current_or_unpersisted_binding_payload)
  end

  private

  def current_or_unpersisted_binding_payload
    binding = Current.account.telephony_telegram_operator_bindings.find_by(user_id: Current.user.id)
    return binding.status_payload if binding

    Current.account.telephony_telegram_operator_bindings.build(user: Current.user).status_payload
  end

  def find_or_create_binding!
    Current.account.telephony_telegram_operator_bindings.find_or_create_by!(user_id: Current.user.id)
  end

  def ensure_bot_configured!
    return if TelegramCalls::Config.configured?

    raise Telephony::Error.new(
      code: 'TELEGRAM_CALLS_BOT_UNCONFIGURED',
      message: 'Telegram calls bot is not configured on this server',
      status: :service_unavailable
    )
  end
end
