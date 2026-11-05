module TelegramCalls::SipEventAccess
  private

  def revoke_disabled_line?(account:, user:)
    return false unless @payload['event_type'].in?(%w[sip_line.heartbeat sip_line.incoming_call sip_line.disconnected])
    return false if TelegramCalls::Config.enabled_for?(account)

    decline_stale_gateway_incoming!(@payload['call_ref']) if @payload['event_type'] == 'sip_line.incoming_call'
    account.telephony_telegram_operator_bindings.find_by(user_id: user.id)&.go_off_line!
    true
  end
end
