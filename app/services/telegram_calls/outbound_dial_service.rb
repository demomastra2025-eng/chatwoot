class TelegramCalls::OutboundDialService
  def self.bridge_answered_operator_leg!(leg:)
    data = leg.deep_stringify_keys
    account = Account.find(data['account_id'])
    user = account.users.find(data['user_id'])
    call_session = ingest_outbound_call_session!(account: account, user: user, leg: data)
    dial_and_activate_outbound!(data: data, call_session: call_session)
  rescue StandardError => e
    handle_outbound_dial_failure!(data: data, account: account, user: user, call_session: call_session, error: e)
  end

  def self.dial_and_activate_outbound!(data:, call_session:)
    TelegramCalls::GatewaySoftphoneClient.new.dial_sip!(
      leg_id: data['leg_id'],
      line_key: data['line_key'],
      number: data['caller_phone'],
      call_ref: call_session.external_call_ref
    )
    TelegramCalls::Registry.update_leg!(data['leg_id'], 'status' => 'in_progress', 'claimed' => true)
    update_outbound_card_active(data)
    { ok: true, call_ref: call_session.external_call_ref }
  end

  def self.handle_outbound_dial_failure!(data:, account:, user:, call_session:, error:)
    Rails.logger.warn("TELEGRAM_CALLS_OUTBOUND_DIAL_FAILED leg=#{data&.dig('leg_id')} error=#{error.class}: #{error.message}")
    fail_outbound_session(account: account, user: user, call_session: call_session)
    terminate_failed_outbound_leg(data)
    { ok: false, error: error.message }
  end

  def self.fail_outbound_session(account:, user:, call_session:)
    return if account.blank? || user.blank? || call_session.blank? || call_session.terminal?

    Telephony::OperatorCallRejectService.new(
      account: account, user: user, call_ref: call_session.external_call_ref,
      status: 'failed', reason: 'outbound_dial_failed'
    ).perform
  rescue StandardError
    nil
  end

  def self.terminate_failed_outbound_leg(data)
    return if data.blank?

    client = TelegramCalls::GatewaySoftphoneClient.new
    client.terminate_leg!(leg_id: data['leg_id'], reason: 'outbound_dial_failed') if client.configured?
  rescue StandardError
    nil
  ensure
    if data.present? && data['leg_id'].present?
      TelegramCalls::Registry.update_leg!(data['leg_id'], 'status' => 'cancelled')
      TelegramCalls::LegCanceller.update_card_status(data, '⚠️ Не удалось соединить исходящий вызов', state: :ended)
    end
  end

  def self.ingest_outbound_call_session!(account:, user:, leg:)
    call_ref = leg['source_call_ref']
    event_key = "tg_softphone:outbound:#{call_ref}"
    Telephony::EventsIngestionService.new(
      payload: {
        account_id: account.id, inbox_id: leg['inbox_id'], provider: leg['provider'],
        call_ref: call_ref, event_key: event_key, event_id: event_key,
        event_type: 'initiated', status: 'ringing', direction: 'outbound',
        to_number: leg['caller_phone'], occurred_at: Time.current.iso8601(3),
        metadata: { route_action: 'operator', direction: 'outbound', chatwoot_user_id: user.id }
      }
    ).perform
  end

  def self.update_outbound_card_active(leg)
    return if leg['chat_id'].blank? || leg['message_id'].blank?

    text = TelegramCalls::CallerCardBuilder.build_text(
      meta: leg, status_line: '📞 <b>Набираем номер клиента...</b>'
    )
    markup = TelegramCalls::BotClient.call_inline_keyboard(leg_id: leg['leg_id'], state: :active)
    TelegramCalls::BotClient.new.edit_message_text(
      chat_id: leg['chat_id'], message_id: leg['message_id'], text: text, reply_markup: markup
    )
  end

  def initialize(binding:, raw_number:, bot_client: TelegramCalls::BotClient.new, gateway_client: TelegramCalls::GatewaySoftphoneClient.new)
    @binding = binding
    @account = binding.account
    @user = binding.user
    @raw_number = raw_number.to_s.strip
    @bot_client = bot_client
    @gateway_client = gateway_client
  end

  def perform!
    number = self.class.normalize_number(@raw_number)
    raise_invalid_number! if number.blank?
    line = select_registered_line
    raise_no_sip_line! if line.blank?

    initiate_operator_callback!(number: number, line: line)
  end

  def self.normalize_number(value)
    digits = value.to_s.gsub(/\D/, '')
    return nil if digits.length < 7

    digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
    "+#{digits}"
  end

  private

  def select_registered_line
    @binding.registered_sip_lines.find { |item| item['registered'] == true }
  end

  def initiate_operator_callback!(number:, line:)
    leg_id = SecureRandom.uuid
    call_ref = "#{line['provider']}:janus:tgout:#{leg_id}"
    leg_meta = build_outbound_leg_meta(leg_id: leg_id, call_ref: call_ref, number: number, line: line)
    TelegramCalls::Registry.store_leg!(leg_meta)
    TelegramCalls::Registry.append_leg_to_source!(
      source_type: 'telephony_sip_outbound', account_id: @account.id, source_call_ref: call_ref, leg_id: leg_id
    )
    send_outbound_card_and_ring!(leg_meta)
  end

  def build_outbound_leg_meta(leg_id:, call_ref:, number:, line:)
    contact = @account.contacts.find_by(phone_number: number)
    inbox = @account.inboxes.find_by(id: line['inbox_id'])
    {
      'leg_id' => leg_id, 'group_id' => leg_id,
      'source_type' => 'telephony_sip_outbound', 'source_call_ref' => call_ref,
      'account_id' => @account.id, 'inbox_id' => inbox&.id, 'user_id' => @user.id, 'binding_id' => @binding.id,
      'chat_id' => @binding.telegram_chat_id, 'line_key' => line['line_key'], 'provider' => line['provider'],
      'provider_label' => TelegramCalls::CallerCardBuilder.provider_label(line['provider']),
      'caller_title' => contact&.name.presence || number, 'caller_phone' => number, 'inbox_name' => inbox&.name,
      'status' => 'ringing', 'voice_ring_started' => true
    }
  end

  def send_outbound_card_and_ring!(leg_meta)
    text = TelegramCalls::CallerCardBuilder.build_text(
      meta: leg_meta, status_line: '🔔 <b>Примите входящий вызов от бота</b>, чтобы соединиться с клиентом'
    )
    markup = TelegramCalls::BotClient.call_inline_keyboard(leg_id: leg_meta['leg_id'], state: :ringing)
    msg = @bot_client.send_message(chat_id: @binding.telegram_chat_id, text: text, reply_markup: markup)
    updated_meta = TelegramCalls::Registry.update_leg!(leg_meta['leg_id'], 'message_id' => msg&.dig('message_id')) || leg_meta
    ring_operator_in_gateway!(updated_meta)
    updated_meta
  end

  def ring_operator_in_gateway!(leg_meta)
    @gateway_client.create_leg!(
      leg_id: leg_meta['leg_id'],
      source_type: 'telephony_sip_outbound',
      source_call_ref: leg_meta['source_call_ref'],
      account_id: @account.id,
      user_id: @user.id,
      operator_telegram_user_id: @binding.telegram_user_id.to_s,
      operator_telegram_username: @binding.username,
      operator_phone: @binding.phone_number,
      callback_url: TelegramCalls::Config.callback_url.presence,
      callback_token: TelegramCalls::Config.callback_token.presence,
      metadata: { group_id: leg_meta['group_id'], caller_label: leg_meta['caller_title'] }.compact
    )
  end

  def raise_invalid_number!
    raise Telephony::Error.new(code: 'INVALID_PHONE_NUMBER', message: 'Укажите корректный номер телефона', status: :unprocessable_content)
  end

  def raise_no_sip_line!
    raise Telephony::Error.new(code: 'NO_ACTIVE_SIP_LINE', message: 'Нет активной SIP-линии. Выйдите на линию.', status: :unprocessable_content)
  end
end
