class TelegramCalls::ClaimCoordinator
  PRIVACY_WARNING = [
    '⚠️ <b>Голосовой вызов Telegram заблокирован настройками приватности.</b>',
    'Откройте Telegram → Настройки → Конфиденциальность → Звонки → разрешите вызовы, или отправьте свой номер кнопкой ниже.'
  ].join("\n").freeze

  def initialize(payload:, gateway_client: TelegramCalls::GatewaySoftphoneClient.new, bot_client: TelegramCalls::BotClient.new)
    @payload = payload.to_h.deep_stringify_keys
    @gateway_client = gateway_client
    @bot_client = bot_client
  end

  def perform
    event_type = @payload['event_type'].to_s
    return TelegramCalls::SipEventProcessor.new(payload: @payload).perform if event_type.start_with?('sip_line.')

    leg = TelegramCalls::Registry.fetch_leg(@payload['leg_id'])
    return { ignored: 'unknown_leg' } if leg.blank?

    dispatch_leg_event(event_type, leg)
  end

  private

  def dispatch_leg_event(event_type, leg)
    case event_type
    when 'operator_leg.ringing'
      TelegramCalls::Registry.update_leg!(leg['leg_id'], 'status' => 'ringing')
      { ok: true }
    when 'operator_leg.privacy_restricted'
      handle_privacy_restricted(leg)
    when 'operator_leg.answered'
      handle_leg_answered(leg)
    when 'operator_leg.ended'
      TelegramCalls::LegEndProcessor.new(leg: leg, payload: @payload, gateway_client: @gateway_client).perform
    else
      { ignored: event_type }
    end
  end

  def handle_privacy_restricted(leg)
    TelegramCalls::Registry.update_leg!(leg['leg_id'], 'status' => 'privacy_restricted')
    TelegramCalls::LegCanceller.update_card_status(leg, PRIVACY_WARNING, state: :ringing)
    prompt_phone_share(leg)
    { ok: true, status: 'privacy_restricted' }
  end

  def prompt_phone_share(leg)
    return if leg['chat_id'].blank?

    @bot_client.send_message(
      chat_id: leg['chat_id'],
      text: 'Нажмите кнопку ниже, чтобы привязать ваш номер телефона для входящих звонков линии OneLink:',
      reply_markup: TelegramCalls::BotClient.operator_reply_keyboard(on_line: true, needs_phone: true)
    )
  end

  def handle_leg_answered(leg)
    return TelegramCalls::OutboundDialService.bridge_answered_operator_leg!(leg: leg) if leg['source_type'] == 'telephony_sip_outbound'

    unless acquire_source_claim(leg)
      reject_losing_leg!(leg)
      return { ok: true, claimed: false }
    end

    bridge_claimed_leg!(leg)
  end

  def acquire_source_claim(leg)
    TelegramCalls::Registry.try_claim_source!(
      source_type: leg['source_type'], account_id: leg['account_id'],
      source_call_ref: leg['source_call_ref'], leg_id: leg['leg_id'], user_id: leg['user_id']
    )
  end

  def bridge_claimed_leg!(leg)
    account = Account.find(leg['account_id'])
    user = account.users.find(leg['user_id'])
    case leg['source_type']
    when 'whatsapp' then bridge_whatsapp_call!(account: account, user: user, leg: leg)
    when 'telegram_personal' then bridge_telegram_personal_call!(account: account, user: user, leg: leg)
    when 'telephony_sip' then bridge_telephony_sip_call!(account: account, user: user, leg: leg)
    end
    finalize_claimed_winner!(leg: leg, user: user)
  rescue StandardError => e
    handle_bridge_failure!(leg, e)
  end

  def bridge_whatsapp_call!(account:, user:, leg:)
    call = account.calls.whatsapp.find(leg['source_call_ref'])
    ensure_voip_call_ringing!(call)
    service = Whatsapp::CallService.new(call: call, agent: user)
    service.accept
    attach_whatsapp_webrtc!(call.reload, service, leg) if call.media_server_enabled? && call.media_session_id.present?
  end

  def attach_whatsapp_webrtc!(call, service, leg)
    offer = service.agent_offer.to_h.stringify_keys
    answer = @gateway_client.attach_webrtc!(
      leg_id: leg['leg_id'], sdp_offer: offer['sdp_offer'], ice_servers: offer['ice_servers'] || []
    )
    Whatsapp::MediaServerClient.new.set_agent_answer(
      call.media_session_id, sdp_answer: answer['sdp_answer'], peer_id: offer['peer_id']
    )
  end

  def bridge_telegram_personal_call!(account:, user:, leg:)
    call = account.calls.telegram_personal.find(leg['source_call_ref'])
    reserve_telegram_personal_call!(call, user)
    raw_call_id = call.media_session_id.presence || call.provider_call_id.to_s.sub(/\A#{call.inbox_id}:/, '')
    @gateway_client.bridge_telegram!(
      leg_id: leg['leg_id'], payload: { channel_id: call.inbox.channel.id, call_id: raw_call_id }
    )
    finalize_telegram_personal_accept!(call, user)
  end

  def finalize_telegram_personal_accept!(call, user)
    TelegramPersonal::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: user)
    conv = call.conversation
    conv&.update!(additional_attributes: (conv.additional_attributes || {}).merge('call_status' => 'in-progress'))
    TelegramPersonal::CallBroadcaster.broadcast_accepted(call, user)
  end

  def reserve_telegram_personal_call!(call, user)
    call.with_lock do
      call.reload
      ensure_voip_call_ringing!(call)
      call.update!(status: 'in_progress', accepted_by_agent_id: user.id, started_at: Time.current)
    end
  end

  def bridge_telephony_sip_call!(account:, user:, leg:)
    call_ref = leg['source_call_ref']
    Telephony::OperatorCallClaimService.new(account: account, user: user, call_ref: call_ref).perform
    @gateway_client.bridge_sip!(
      leg_id: leg['leg_id'], line_key: leg['line_key'], janus_call_id: leg['janus_call_id'], call_ref: call_ref
    )
    Telephony::OperatorCallAnsweredService.new(account: account, user: user, call_ref: call_ref).perform
    cancel_sibling_telephony_sessions!(account: account, leg: leg, winner_name: user.name)
  end

  def cancel_sibling_telephony_sessions!(account:, leg:, winner_name:)
    group_ref = leg['logical_group_ref'].presence
    return if group_ref.blank?

    siblings = account.telephony_call_sessions.where("metadata->>'logical_call_group_ref' = ?", group_ref)
    siblings.find_each do |session|
      next if session.external_call_ref == leg['source_call_ref']

      cancel_sibling_session_legs!(account.id, session.external_call_ref, winner_name)
    end
  end

  def cancel_sibling_session_legs!(account_id, sibling_ref, winner_name)
    group = TelegramCalls::Registry.fetch_source_group(
      source_type: 'telephony_sip', account_id: account_id, source_call_ref: sibling_ref
    )
    Array.wrap(group&.dig('leg_ids')).each do |sib_leg_id|
      TelegramCalls::LegCanceller.cancel_single_leg!(
        leg_id: sib_leg_id, status_text: "ℹ️ Принял(а): #{ERB::Util.html_escape(winner_name)}", decline_sip: true
      )
    end
  end

  def finalize_claimed_winner!(leg:, user:)
    TelegramCalls::Registry.update_leg!(leg['leg_id'], 'status' => 'in_progress', 'claimed' => true)
    TelegramCalls::LegCanceller.cancel_for_source!(
      source_type: leg['source_type'], account_id: leg['account_id'], source_call_ref: leg['source_call_ref'],
      except_leg_id: leg['leg_id'], status_text: "ℹ️ Принял(а): #{ERB::Util.html_escape(user.name)}"
    )
    TelegramCalls::LegCanceller.update_card_status(leg, '🟢 <b>Разговор идёт</b>', state: :active)
    { ok: true, claimed: true }
  end

  def handle_bridge_failure!(leg, error)
    Rails.logger.warn("TELEGRAM_CALLS_CLAIM_FAILED leg=#{leg['leg_id']} error=#{error.class}: #{error.message}")
    TelegramCalls::Registry.release_claim_source!(
      source_type: leg['source_type'], account_id: leg['account_id'], source_call_ref: leg['source_call_ref']
    )
    reject_losing_leg!(leg, message: 'ℹ️ Звонок уже недоступен или принят другим оператором')
    { ok: false, error: error.message }
  end

  def reject_losing_leg!(leg, message: 'ℹ️ Звонок уже принял другой сотрудник')
    @gateway_client.terminate_leg!(leg_id: leg['leg_id'], reason: 'answered_elsewhere') if @gateway_client.configured?
    TelegramCalls::Registry.update_leg!(leg['leg_id'], 'status' => 'cancelled')
    TelegramCalls::LegCanceller.update_card_status(leg, message, state: :ended)
  rescue StandardError
    nil
  end

  def ensure_voip_call_ringing!(call)
    return if call.ringing? && call.accepted_by_agent_id.blank?

    raise Telephony::Error.new(code: 'CALL_ALREADY_CLAIMED', message: 'Call already handled', status: :conflict)
  end
end
